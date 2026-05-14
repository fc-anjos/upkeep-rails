module ActiveRecord
  class Base
    def self.q(str)
      ActiveRecord::Base.connection.quote(str)
    end

    def q(str)
      ActiveRecord::Base.connection.quote(str)
    end
  end
end

class String
  def forcibly_convert_to_utf8
    begin
      return self if self.encoding.to_s == "UTF-8" && self.valid_encoding?

      str = self.dup.force_encoding("binary").encode(
        "utf-8",
        invalid: :replace,
        undef: :replace,
        replace: "?"
      )

      raise Encoding::UndefinedConversionError if !str.valid_encoding? || str.encoding.to_s != "UTF-8"

    rescue Encoding::UndefinedConversionError
      str = self.chars.map { |c|
        begin
          c.encode("UTF-8", invalid: :replace, undef: :replace)
        rescue
          "?".encode("UTF-8")
        end
      }.join

      raise "still bogus encoding" if !str.valid_encoding?
    end

    str
  end
end
