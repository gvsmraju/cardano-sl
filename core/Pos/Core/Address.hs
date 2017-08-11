module Pos.Core.Address
       ( Address (..)
       , AddrPkAttrs (..)
       , addressF
       , addressDetailedF
       , checkPubKeyAddress
       , checkScriptAddress
       , checkRedeemAddress
       , checkUnknownAddressType
       , makePubKeyAddress
       , makePubKeyHdwAddress
       , createHDAddressNH
       , createHDAddressH
       , makeScriptAddress
       , makeRedeemAddress
       , decodeTextAddress
       , deriveLvl2KeyPair

       , StakeholderId

         -- * Internals
       , AddressHash
       , addressHash
       , unsafeAddressHash
       ) where

import           Universum

import           Control.Lens           (_Left)
import           Crypto.Hash            (Blake2b_224, Digest, SHA3_256)
import qualified Crypto.Hash            as CryptoHash
import           Data.ByteString.Base58 (Alphabet (..), bitcoinAlphabet, decodeBase58,
                                         encodeBase58)
import           Data.Hashable          (Hashable (..))
import           Data.Text.Buildable    (Buildable)
import qualified Data.Text.Buildable    as Buildable
import           Formatting             (Format, bprint, build, int, later, (%))
import           Serokell.Util.Base16   (base16F)

import           Pos.Binary.Class       (Bi)
import qualified Pos.Binary.Class       as Bi
import           Pos.Binary.Crypto      ()
import           Pos.Core.Types         (AddrPkAttrs (..), Address (..), AddressHash,
                                         Script, StakeholderId)
import           Pos.Crypto             (AbstractHash (AbstractHash), EncryptedSecretKey,
                                         PublicKey, RedeemPublicKey, encToPublic,
                                         hashHexF)
import           Pos.Crypto.HD          (HDAddressPayload, HDPassphrase,
                                         deriveHDPassphrase, deriveHDPublicKey,
                                         deriveHDSecretKey, packHDAddressAttr)
import           Pos.Crypto.SafeSigning (PassPhrase)
import           Pos.Data.Attributes    (mkAttributes)

instance Bi Address => Hashable Address where
    hashWithSalt s = hashWithSalt s . Bi.serialize'

-- | Currently we gonna use Bitcoin alphabet for representing addresses in
-- base58
addrAlphabet :: Alphabet
addrAlphabet = bitcoinAlphabet

addrToBase58 :: Bi Address => Address -> ByteString
addrToBase58 = encodeBase58 addrAlphabet . Bi.serialize'

instance Bi Address => Buildable Address where
    build = Buildable.build . decodeUtf8 @Text . addrToBase58

-- | A function which decodes base58 address from given ByteString
decodeAddress :: Bi Address => ByteString -> Either String Address
decodeAddress bs = do
    let base58Err = "Invalid base58 representation of address"
    dbs <- maybeToRight base58Err $ decodeBase58 addrAlphabet bs
    over _Left toString $ Bi.decodeFull dbs

decodeTextAddress :: Bi Address => Text -> Either Text Address
decodeTextAddress = first toText . decodeAddress . encodeUtf8

-- | A function for making an address from PublicKey
makePubKeyAddress :: Bi PublicKey => PublicKey -> Address
makePubKeyAddress key =
    PubKeyAddress (addressHash key)
                  (mkAttributes (AddrPkAttrs Nothing))

-- | A function for making an HDW address
makePubKeyHdwAddress
    :: Bi PublicKey
    => HDAddressPayload    -- ^ Derivation path
    -> PublicKey
    -> Address
makePubKeyHdwAddress path key =
    PubKeyAddress (addressHash key)
                  (mkAttributes (AddrPkAttrs (Just path)))

-- | Create address from secret key in hardened way.
createHDAddressH
    :: PassPhrase
    -> HDPassphrase
    -> EncryptedSecretKey
    -> [Word32]
    -> Word32
    -> Maybe (Address, EncryptedSecretKey)
createHDAddressH passphrase walletPassphrase parent parentPath childIndex = do
    derivedSK <- deriveHDSecretKey passphrase parent childIndex
    let addressPayload = packHDAddressAttr walletPassphrase $ parentPath ++ [childIndex]
    let pk = encToPublic derivedSK
    return (makePubKeyHdwAddress addressPayload pk, derivedSK)

-- | Create address from public key via non-hardened way.
createHDAddressNH :: HDPassphrase -> PublicKey -> [Word32] -> Word32 -> (Address, PublicKey)
createHDAddressNH passphrase parent parentPath childIndex = do
    let derivedPK = deriveHDPublicKey parent childIndex
    let addressPayload = packHDAddressAttr passphrase $ parentPath ++ [childIndex]
    (makePubKeyHdwAddress addressPayload derivedPK, derivedPK)

-- | A function for making an address from a validation script
makeScriptAddress :: Bi Script => Script -> Address
makeScriptAddress scr = ScriptAddress (addressHash scr)

-- | A function for making an address from a redeem script
makeRedeemAddress :: Bi RedeemPublicKey => RedeemPublicKey -> Address
makeRedeemAddress key = RedeemAddress (addressHash key)

-- CHECK: @checkPubKeyAddress
-- | Check if given 'Address' is created from given 'PublicKey'
checkPubKeyAddress :: Bi PublicKey => PublicKey -> Address -> Bool
checkPubKeyAddress key (PubKeyAddress h _) = addressHash key == h
checkPubKeyAddress _ _                     = False

-- | Check if given 'Address' is created from given validation script
checkScriptAddress :: Bi Script => Script -> Address -> Bool
checkScriptAddress scr (ScriptAddress h) = addressHash scr == h
checkScriptAddress _ _                   = False

-- | Check if given 'Address' is created from given 'RedeemPublicKey'
checkRedeemAddress :: Bi RedeemPublicKey => RedeemPublicKey -> Address -> Bool
checkRedeemAddress key (RedeemAddress h) = addressHash key == h
checkRedeemAddress _ _                   = False

-- | Check if given 'Address' has given type
checkUnknownAddressType :: Word8 -> Address -> Bool
checkUnknownAddressType t addr = case addr of
    PubKeyAddress{}        -> t == 0
    ScriptAddress{}        -> t == 1
    RedeemAddress{}        -> t == 2
    UnknownAddressType p _ -> t == p

-- | Specialized formatter for 'Address'.
addressF :: Bi Address => Format r (Address -> r)
addressF = build

instance Buildable AddrPkAttrs where
    build (AddrPkAttrs p) = case p of
        Nothing -> "{}"
        Just _  -> bprint ("{path is encrypted}")

-- | A formatter showing guts of an 'Address'.
addressDetailedF :: Format r (Address -> r)
addressDetailedF = later $ \case
    PubKeyAddress x attrs ->
        bprint ("PubKeyAddress "%hashHexF%" (attrs: "%build%")") x attrs
    ScriptAddress x ->
        bprint ("ScriptAddress "%hashHexF) x
    RedeemAddress x ->
        bprint ("RedeemAddress "%hashHexF) x
    UnknownAddressType t bs ->
        bprint ("UnknownAddressType "%int%" "%base16F) t bs

----------------------------------------------------------------------------
-- Hashing
----------------------------------------------------------------------------

unsafeAddressHash :: Bi a => a -> AddressHash b
unsafeAddressHash = AbstractHash . secondHash . firstHash
  where
    firstHash :: Bi a => a -> Digest SHA3_256
    firstHash = CryptoHash.hash . Bi.serialize'
    secondHash :: Digest SHA3_256 -> Digest Blake2b_224
    secondHash = CryptoHash.hash

addressHash :: Bi a => a -> AddressHash a
addressHash = unsafeAddressHash

----------------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------------

-- | Makes account secret key for given wallet set.
deriveLvl2KeyPair
    :: PassPhrase
    -> EncryptedSecretKey  -- ^ key of wallet set
    -> Word32              -- ^ wallet derivation index
    -> Word32              -- ^ account derivation index
    -> Maybe (Address, EncryptedSecretKey)
deriveLvl2KeyPair passphrase wsKey walletIndex accIndex = do
    wKey <- deriveHDSecretKey passphrase wsKey walletIndex
    let hdPass = deriveHDPassphrase $ encToPublic wsKey
    createHDAddressH passphrase hdPass wKey [walletIndex] accIndex
