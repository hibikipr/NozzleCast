require "minitest/autorun"
require "webrick"
require "json"
require "metadata_sync/http_transport"

class PingServlet < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, received_box)
    super(server)
    @received_box = received_box
  end

  def do_GET(req, res)
    @received_box[:method] = req.request_method
    @received_box[:auth] = req.header["authorization"]&.first
    @received_box[:body] = req.body
    res.status = 200
    res.body = JSON.generate({ "data" => { "ok" => true } })
  end

  def do_PATCH(req, res)
    @received_box[:method] = req.request_method
    @received_box[:auth] = req.header["authorization"]&.first
    @received_box[:body] = req.body
    res.status = 200
    res.body = JSON.generate({ "data" => { "ok" => true } })
  end
end

class HttpTransportTest < Minitest::Test
  def setup
    @received = {}
    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount("/v1/ping", PingServlet, @received)
    @thread = Thread.new { @server.start }
    sleep 0.05 until @server.status == :Running
  end

  def teardown
    @server.shutdown
    @thread.join
  end

  def transport
    MetadataSync::HttpTransport.new(token: "tok123", base_url: "http://127.0.0.1:#{@server.config[:Port]}")
  end

  def test_get_sends_bearer_token_and_parses_json
    result = transport.get("/v1/ping")
    assert_equal({ "ok" => true }, result["data"])
    assert_equal "GET", @received[:method]
    assert_equal "Bearer tok123", @received[:auth]
  end

  def test_patch_sends_json_body
    transport.patch("/v1/ping", { "data" => { "id" => "1" } })
    assert_equal "PATCH", @received[:method]
    assert_equal({ "data" => { "id" => "1" } }, JSON.parse(@received[:body]))
  end
end
