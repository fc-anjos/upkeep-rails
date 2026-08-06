module Upkeep
  # Ambient identity choke points. Any observed read of session, cookies, or
  # CurrentAttributes during a capture marks the recording as
  # identity-tainted: its surfaces are permanently Tier P for this deploy.
  #
  # `unobserved` is the sanctioned escape hatch for identity *declaration*
  # (a controller resolving current_user from the session). Code that uses
  # it to smuggle personalization past the choke points is exactly what the
  # digest-divergence and scrubbed-render defenses exist for.
  module Ambient
    UNOBSERVED_KEY = :upkeep_ambient_unobserved

    def self.unobserved
      prev = Thread.current[UNOBSERVED_KEY]
      Thread.current[UNOBSERVED_KEY] = true
      yield
    ensure
      Thread.current[UNOBSERVED_KEY] = prev
    end

    def self.observe(reason)
      return if Thread.current[UNOBSERVED_KEY]
      Recording.current&.ambient!(reason)
    end

    # Framework-infrastructure session keys, derived from framework
    # structure (never app conventions): Rails reads flash and the CSRF
    # token on essentially every request, and Warden/Devise resolve the
    # authenticated user from "warden.*" keys. Observing those reads would
    # identity-taint every page of every real app and Tier S would never
    # engage anywhere. Reads of these keys are sanctioned identity/plumbing
    # doors — exactly like a viewer_resolver going through `unobserved` —
    # and anything personal they influence in the OUTPUT is still caught by
    # digest divergence and the scrubbed render. App-level session keys
    # remain observed and taint as before.
    INFRASTRUCTURE_SESSION_KEYS = [
      "flash", "_csrf_token", "session_id", /\Awarden\./
    ].freeze

    class << self
      attr_writer :sanctioned_session_keys
      def sanctioned_session_keys = @sanctioned_session_keys ||= INFRASTRUCTURE_SESSION_KEYS.dup

      def infrastructure_session_key?(key)
        k = key.to_s
        sanctioned_session_keys.any? { |p| p.is_a?(Regexp) ? p.match?(k) : p == k }
      end

      # Same reasoning for cookies: the session store loads the session
      # cookie through the jar on every request. Only the app's session
      # cookie (from session_options) is sanctioned by default.
      attr_writer :sanctioned_cookie_keys
      def sanctioned_cookie_keys
        @sanctioned_cookie_keys ||= [
          (::Rails.application.config.session_options[:key] if defined?(::Rails) && ::Rails.application)
        ].compact
      end

      def infrastructure_cookie_key?(key)
        sanctioned_cookie_keys.map(&:to_s).include?(key.to_s)
      end
    end

    module SessionObserver
      # Keyed reads observe only non-infrastructure keys; whole-session
      # reads (to_h etc.) always observe — they see everything.
      %i[[] fetch dig].each do |m|
        define_method(m) do |*args, &block|
          Ambient.observe(:session_read) unless args.first && Ambient.infrastructure_session_key?(args.first)
          super(*args, &block)
        end
      end

      %i[to_h to_hash values].each do |m|
        define_method(m) do |*args, &block|
          Ambient.observe(:session_read)
          super(*args, &block)
        end
      end
    end

    module CookieObserver
      def [](name)
        Ambient.observe(:cookie_read) unless Ambient.infrastructure_cookie_key?(name)
        super
      end
    end

    # CurrentAttributes readers are generated per-attribute with no shared
    # choke point (they read @attributes directly), so we wrap the generator:
    # every attribute defined after install gets an observing reader.
    module CurrentAttributesObserver
      def attribute(*names, **options)
        result = super
        observer = Module.new do
          names.each do |name|
            define_method(name) do
              Ambient.observe(:current_attributes_read)
              super()
            end
          end
        end
        prepend(observer)
        result
      end
    end

    def self.install!
      ActionDispatch::Request::Session.prepend(SessionObserver)
      ActionDispatch::Cookies::CookieJar.prepend(CookieObserver)
      ActiveSupport::CurrentAttributes.singleton_class.prepend(CurrentAttributesObserver)
    end
  end
end
