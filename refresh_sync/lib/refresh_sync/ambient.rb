module RefreshSync
  # Ambient identity choke points. Any observed read of session, cookies, or
  # CurrentAttributes during a capture marks the recording as
  # identity-tainted: its surfaces are permanently Tier P for this deploy.
  #
  # `unobserved` is the sanctioned escape hatch for identity *declaration*
  # (a controller resolving current_user from the session). Code that uses
  # it to smuggle personalization past the choke points is exactly what the
  # digest-divergence and scrubbed-render defenses exist for.
  module Ambient
    UNOBSERVED_KEY = :refresh_sync_ambient_unobserved

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

    module SessionObserver
      %i[[] fetch dig to_h to_hash values].each do |m|
        define_method(m) do |*args, &block|
          Ambient.observe(:session_read)
          super(*args, &block)
        end
      end
    end

    module CookieObserver
      def [](name)
        Ambient.observe(:cookie_read)
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
