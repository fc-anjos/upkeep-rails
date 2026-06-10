# frozen_string_literal: true

require "test_helper"

class ClientSubscriptionTest < Minitest::Test
  FakeIdentity = Struct.new(:stream_name)
  FakeSubscription = Struct.new(:id)

  def test_marker_carries_payload_as_attributes_with_no_text_content
    marker = Upkeep::Rails::ClientSubscription.marker_for(
      identity: FakeIdentity.new("upkeep:test:stream-1"),
      subscription: FakeSubscription.new("sub-123")
    )
    tag, content = marker.match(%r{\A(<upkeep-subscription-source [^>]*>)(.*)</upkeep-subscription-source>\z}m).captures

    assert_equal "", content
    assert_includes tag, %(id="upkeep-subscription-source-sub-123")
    assert_includes tag, %(channel="Upkeep::Rails::Cable::Channel")
    assert_includes tag, %(subscription-id="sub-123")
    assert_includes tag, %(stream-name="upkeep:test:stream-1")
    assert_includes tag, %(hidden style="display:none")
    assert_includes tag, "data-upkeep-subscription"
    assert_includes tag, "data-turbo-temporary"
    token = tag[/activation-token="([^"]*)"/, 1]
    assert Upkeep::Rails::ActivationToken.valid_for_subscription?(CGI.unescapeHTML(token), "sub-123")
  end

  def test_marker_escapes_attribute_values
    marker = Upkeep::Rails::ClientSubscription.marker_for(
      identity: FakeIdentity.new(%(stream"with<markup>&amp)),
      subscription: FakeSubscription.new("sub-123")
    )

    assert_includes marker, %(stream-name="stream&quot;with&lt;markup&gt;&amp;amp")
  end
end
