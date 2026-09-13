require "jwt"
require "openssl"

module MetadataSync
  class Auth
    AUDIENCE = "appstoreconnect-v1".freeze
    TOKEN_LIFETIME_SECONDS = 15 * 60

    def self.build_token(key_id:, issuer_id:, private_key_pem:)
      private_key = OpenSSL::PKey::EC.new(private_key_pem)
      now = Time.now.to_i
      payload = {
        iss: issuer_id,
        iat: now,
        exp: now + TOKEN_LIFETIME_SECONDS,
        aud: AUDIENCE
      }
      headers = { kid: key_id, typ: "JWT" }
      JWT.encode(payload, private_key, "ES256", headers)
    end
  end
end
