module RefreshSync
  # Matching must compare through the column's ActiveRecord type, not Ruby
  # ==: a read set persisted as JSON and reloaded holds "2026-01-01" where a
  # live write holds a Date, "5" where the write holds 5. Both sides of
  # every comparison are cast through the column type first.
  module Coercion
    @types = {}
    @mutex = Mutex.new

    def self.cast(table, attr, value)
      type = type_for(table, attr.to_s)
      type ? type.cast(value) : value
    end

    def self.same?(table, attr, a, b)
      cast(table, attr, a) == cast(table, attr, b)
    end

    def self.type_for(table, attr)
      key = "#{table}.#{attr}"
      @mutex.synchronize do
        return @types[key] if @types.key?(key)
        @types[key] =
          begin
            conn = ActiveRecord::Base.connection
            column = conn.schema_cache.columns_hash(table)[attr]
            # Rails 8.1: lookup_cast_type (from sql_type) is public; the
            # older lookup_cast_type_from_column is gone. On 7.1 the same
            # method exists but is private — send covers both.
            column && conn.send(:lookup_cast_type, column.sql_type)
          rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
            nil
          end
      end
    end

    def self.reset!
      @mutex.synchronize { @types = {} }
    end
  end
end
