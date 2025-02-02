require 'ecdsa_ext'
require 'ecdsa/ext/sign_verify'

module Bitcoin
  module Secp256k1

    # secp256 module using ecdsa gem
    # https://github.com/DavidEGrayson/ruby_ecdsa
    module Ruby

      module_function

      # generate ec private key and public key
      def generate_key_pair(compressed: true)
        private_key = 1 + SecureRandom.random_number(GROUP.order - 1)
        public_key = GROUP.generator.to_jacobian * private_key
        privkey = ECDSA::Format::IntegerOctetString.encode(private_key, 32)
        pubkey = public_key.to_affine.to_hex(compressed)
        [privkey.bth, pubkey]
      end

      # generate bitcoin key object
      def generate_key(compressed: true)
        privkey, pubkey = generate_key_pair(compressed: compressed)
        Bitcoin::Key.new(priv_key: privkey, pubkey: pubkey, compressed: compressed)
      end

      def generate_pubkey(privkey, compressed: true)
        public_key = GROUP.generator.to_jacobian * privkey.to_i(16)
        public_key.to_affine.to_hex(compressed)
      end

      # Check whether valid x-only public key or not.
      # @param [String] pub_key x-only public key with hex format(32 bytes).
      # @return [Boolean] result.
      def valid_xonly_pubkey?(pub_key)
        pubkey = pub_key.htb
        return false unless pubkey.bytesize == X_ONLY_PUBKEY_SIZE
        begin
          ECDSA::Format::PointOctetString.decode(pubkey, ECDSA::Group::Secp256k1)
        rescue Exception
          return false
        end
        true
      end

      # sign data.
      # @param [String] data a data to be signed with binary format
      # @param [String] privkey a private key using sign with hex format
      # @param [String] extra_entropy a extra entropy with binary format for rfc6979
      # @param [Symbol] algo signature algorithm. ecdsa(default) or schnorr.
      # @return [String] signature data with binary format
      def sign_data(data, privkey, extra_entropy = nil, algo: :ecdsa)
        case algo
        when :ecdsa
          sign_ecdsa(data, privkey, extra_entropy)&.first
        when :schnorr
          sign_schnorr(data, privkey, extra_entropy)
        else
          nil
        end
      end

      # Sign data with compact format.
      # @param [String] data a data to be signed with binary format
      # @param [String] privkey a private key using sign with hex format
      # @return [Array[signature, recovery id]]
      def sign_compact(data, privkey)
        sig, rec = sign_ecdsa(data, privkey, nil)
        [ECDSA::Format::SignatureDerString.decode(sig), rec]
      end

      # Recover public key from compact signature.
      # @param [String] data message digest using signature.
      # @param [String] signature signature with binary format.
      # @param [Integer] rec recovery id.
      # @param [Boolean] compressed whether compressed public key or not.
      # @return [Bitcoin::Key] Recovered public key.
      def recover_compact(data, signature, rec, compressed)
        r = ECDSA::Format::IntegerOctetString.decode(signature[1...33])
        s = ECDSA::Format::IntegerOctetString.decode(signature[33..-1])
        ECDSA.recover_public_key(Bitcoin::Secp256k1::GROUP, data, ECDSA::Signature.new(r, s)).each do |p|
          if p.y & 1 == rec
            return Bitcoin::Key.from_point(p, compressed: compressed)
          end
        end
      end

      # verify signature using public key
      # @param [String] data a SHA-256 message digest with binary format
      # @param [String] sig a signature for +data+ with binary format
      # @param [String] pubkey a public key with hex format.
      # @return [Boolean] verify result
      def verify_sig(data, sig, pubkey, algo: :ecdsa)
        case algo
        when :ecdsa
          verify_ecdsa(data, sig, pubkey)
        when :schnorr
          verify_schnorr(data, sig, pubkey)
        else
          false
        end
      end

      # if +pubkey+ is hybrid public key format, it convert uncompressed format.
      # https://lists.linuxfoundation.org/pipermail/bitcoin-dev/2012-June/001578.html
      def repack_pubkey(pubkey)
        p = pubkey.htb
        case p[0]
          when "\x06", "\x07"
            p[0] = "\x04"
            p
          else
            pubkey.htb
        end
      end

      # validate whether this is a valid public key (more expensive than IsValid())
      # @param [String] pubkey public key with hex format.
      # @param [Boolean] allow_hybrid whether support hybrid public key.
      # @return [Boolean] If valid public key return true, otherwise false.
      def parse_ec_pubkey?(pubkey, allow_hybrid = false)
        begin
          point = ECDSA::Format::PointOctetString.decode(pubkey.htb, ECDSA::Group::Secp256k1, allow_hybrid: allow_hybrid)
          ECDSA::Group::Secp256k1.valid_public_key?(point)
        rescue ECDSA::Format::DecodeError
          false
        end
      end

      def sign_ecdsa(data, privkey, extra_entropy)
        privkey = privkey.htb
        private_key = ECDSA::Format::IntegerOctetString.decode(privkey)
        extra_entropy ||= ''
        nonce = RFC6979.generate_rfc6979_nonce(privkey + data, extra_entropy)

        # port form ecdsa gem.
        r_point = (GROUP.generator.to_jacobian * nonce).to_affine

        point_field = ECDSA::PrimeField.new(GROUP.order)
        r = point_field.mod(r_point.x)
        return nil if r.zero?

        rec = r_point.y & 1

        e = ECDSA.normalize_digest(data, GROUP.bit_length)
        s = point_field.mod(point_field.inverse(nonce) * (e + r * private_key))

        if s > (GROUP.order / 2) # convert low-s
          s = GROUP.order - s
          rec ^= 1
        end

        return nil if s.zero?

        signature = ECDSA::Signature.new(r, s).to_der
        public_key = Bitcoin::Key.new(priv_key: privkey.bth).pubkey
        raise 'Creation of signature failed.' unless Bitcoin::Secp256k1::Ruby.verify_sig(data, signature, public_key)
        [signature, rec]
      end

      def sign_schnorr(data, privkey, aux_rand)
        aux_rand ? Schnorr.sign(data, privkey.htb, aux_rand).encode : Schnorr.sign(data, privkey.htb).encode
      end

      def verify_ecdsa(data, sig, pubkey)
        begin
          k = ECDSA::Format::PointOctetString.decode(repack_pubkey(pubkey), GROUP)
          signature = ECDSA::Format::SignatureDerString.decode(sig)
          ECDSA.valid_signature?(k, data, signature)
        rescue Exception
          false
        end
      end

      def verify_schnorr(data, sig, pubkey)
        Schnorr.valid_sig?(data, pubkey.htb, sig)
      end

    end
  end
end
