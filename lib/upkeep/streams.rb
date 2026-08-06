module Upkeep
  # The "browser client" — deliberately zero custom JavaScript.
  #
  # Turbo 8 already ships everything the client contract needs: the
  # <turbo-cable-stream-source> element subscribes, Turbo Streams apply
  # themselves, refresh actions morph, and X-Turbo-Request-Id discard breaks
  # the GET-write loop. Upkeep therefore ships no JS at all:
  #
  # 1. Subscription: Capture injects stock <turbo-cable-stream-source>
  #    elements (cohort stream + each surface stream) before </body>. The
  #    stream name is signed with Turbo's own verifier, so the signed name IS
  #    the activation token: it exists only in the HTML served to the
  #    authenticated viewer, and Turbo::StreamsChannel refuses anything else.
  #    Identity fails closed — an unverifiable name never subscribes.
  # 2. Activation + reconnect resync: server-side, on the channel. The first
  #    verified subscription flips the cohort's activated_at; any later
  #    subscription on the same cohort stream is a reconnect, and the channel
  #    pushes one refresh so a viewer that missed deliveries while
  #    disconnected converges immediately (freshness fails open).
  # 3. Generation ordering (a stale in-flight refresh GET morphing over an
  #    applied region update): accepted as a self-healing transient. Every
  #    artifact renders DB-current state at its own render time, refresh is
  #    idempotent, and the next event converges the page. No client code.
  module Streams
    class << self
      # Kill switch for response-body injection (set false if the app prefers
      # to place the elements itself via layout helper).
      attr_writer :auto_subscribe
      def auto_subscribe = @auto_subscribe.nil? ? true : @auto_subscribe

      def cohort_stream?(name)
        name.is_a?(String) && name.start_with?("upkeep:cohort:")
      end

      # Build the stock Turbo stream source tags for a set of stream names.
      def source_tags(streams)
        streams.map do |stream|
          signed = ::Turbo.signed_stream_verifier.generate(stream)
          %(<turbo-cable-stream-source channel="Turbo::StreamsChannel" signed-stream-name="#{signed}"></turbo-cable-stream-source>)
        end.join
      end

      # Inject subscription elements into a rendered HTML response. No-op
      # (loudly) when the page has no </body> to anchor on.
      def inject_sources(response, streams)
        return if streams.empty?
        body = response.body
        unless body.include?("</body>")
          Upkeep.stats[:subscribe_injection_skipped] += 1
          ActiveSupport::Notifications.instrument(
            "subscribe_injection_skipped.upkeep", reason: :no_body_tag
          )
          return
        end
        tags = source_tags(streams)
        response.body = body.sub("</body>") { tags + "</body>" }
      end

      # Called by the channel hook with the VERIFIED stream name.
      # Returns :first on initial activation, :reconnect when a refresh was
      # pushed, nil for non-cohort streams / unknown cohorts.
      def subscribed(stream_name)
        return nil unless cohort_stream?(stream_name)
        state = Upkeep.store.mark_subscribed(stream_name)
        case state
        when :reconnect
          # The viewer may have missed deliveries while disconnected; one
          # idempotent refresh converges them. Server-side by design — the
          # client has no resync logic to get wrong.
          ::Turbo::StreamsChannel.broadcast_refresh_to(stream_name)
          Upkeep.stats[:reconnect_refreshes] += 1
          ActiveSupport::Notifications.instrument(
            "reconnect_refresh.upkeep", stream: stream_name
          )
        when :first
          Upkeep.stats[:cohorts_activated] += 1
        end
        state
      end
    end

    # Prepended onto Turbo::StreamsChannel: observes verified subscriptions.
    # Verification itself is Turbo's — we never accept a name Turbo rejected.
    module SubscriptionObserver
      def subscribed
        super
        return if subscription_rejected?
        name = self.class.verified_stream_name(params[:signed_stream_name])
        Streams.subscribed(name) if name
      end
    end

    def self.attach!
      return if @attached
      @attached = true
      ::Turbo::StreamsChannel.prepend(SubscriptionObserver)
    end
  end
end
