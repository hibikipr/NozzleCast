require "minitest/autorun"
require "openssl"
require "jwt"
require "metadata_sync/auth"

class AuthTest < Minitest::Test
  def setup
    @key = OpenSSL::PKey::EC.generate("prime256v1")
  end

  def test_build_token_has_correct_claims_and_header
    token = MetadataSync::Auth.build_token(
      key_id: "KID123",
      issuer_id: "ISSUER456",
      private_key_pem: @key.to_pem
    )

    payload, header = JWT.decode(token, @key, true, algorithm: "ES256")

    assert_equal "KID123", header["kid"]
    assert_equal "ISSUER456", payload["iss"]
    assert_equal "appstoreconnect-v1", payload["aud"]
    assert payload["exp"] > payload["iat"]
    assert_operator payload["exp"] - payload["iat"], :<=, 20 * 60
  end
end
