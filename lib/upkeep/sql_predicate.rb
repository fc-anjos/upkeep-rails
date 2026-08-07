module Upkeep
  # A parsed where-clause fragment as a structured, JSON-serializable
  # predicate, evaluable in Ruby under SQL's three-valued logic.
  #
  # Compiled form (all plain hashes/arrays/scalars, so it survives the
  # ActiveRecord store round trip):
  #   {"op" => "and"/"or", "children" => [...]}
  #   {"op" => "not", "child" => node}
  #   {"op" => "cmp", "cmp" => "eq|ne|lt|lte|gt|gte", "col" => c, "v" => val}
  #   {"op" => "null", "col" => c, "negated" => bool}
  #   {"op" => "between", "col" => c, "low" => val, "high" => val, "negated" => bool}
  #   {"op" => "in", "col" => c, "list" => [val...], "negated" => bool}
  #   {"op" => "like", "col" => c, "pattern" => val, "ci" => bool, "negated" => bool}
  #   {"op" => "opaque", "columns" => [...]}   # matchable, never evaluable
  # where val is {"lit" => x} or {"bind" => index}.
  #
  # An expression the compiler does not understand becomes an "opaque" node
  # carrying whatever column names it references: the fragment stays
  # MATCHABLE (its columns participate in disjoint-write reasoning) but that
  # branch always evaluates to UNKNOWN — the conservative verdict. A column
  # qualified with a table outside `table`/`aliases` aborts compilation
  # entirely (the caller degrades, exactly as before the parser existed).
  module SqlPredicate
    CMP_OPS = {
      "Eq" => "eq", "NotEq" => "ne", "Lt" => "lt", "LtEq" => "lte",
      "Gt" => "gt", "GtEq" => "gte"
    }.freeze
    ForeignTable = Class.new(StandardError)

    module_function

    # Compile a parsed where-clause AST (sqlparser JSON) for `table`.
    # Returns {"tree" =>, "columns" =>, "evaluable" => bool} — raises for
    # anything referencing a table that is not `table` (or an alias of it);
    # SqlAnalysis catches and caches the failure as opaque.
    def compile(ast, table:, aliases: {}, covered: [])
      context = { table: table.to_s, aliases: aliases, covered: covered.map(&:to_s),
                  columns: [], opaque: false }
      tree = node(ast, context)
      {
        "tree" => tree,
        "columns" => context[:columns].uniq,
        "evaluable" => !context[:opaque]
      }
    end

    # A cached compile is shape-only; the capture-time bind values ride the
    # stored fragment. (Fragment hashes live inside ReadSet predicate lists
    # under the "__fragment__" key.)
    def with_binds(compiled, binds)
      compiled.merge("binds" => binds.map { |b| plain_value(b) })
    end

    def fragment?(pred)
      pred.is_a?(Hash) && (pred.key?("__fragment__") || pred.key?(:__fragment__))
    end

    def unwrap(pred)
      pred["__fragment__"] || pred[:__fragment__]
    end

    # --- evaluation (three-valued) ------------------------------------------
    # attrs: {column => value}; a column missing from attrs is UNKNOWN.
    # Returns true / false / nil.
    def evaluate(fragment, table, attrs)
      eval_node(fragment["tree"], table, attrs, fragment["binds"] || [])
    rescue StandardError
      nil
    end

    # Every literal/bind value in the fragment (temporal-expiry scanning).
    def literal_values(fragment)
      values = (fragment["binds"] || []).dup
      collect_literals(fragment["tree"], values)
      values
    end

    # --- compilation ---------------------------------------------------------

    def node(ast, context)
      key, body = ast.first
      case key
      when "Nested" then node(body, context)
      when "BinaryOp" then binary(body, context)
      when "UnaryOp" then unary(body, context)
      when "IsNull" then null_node(body, context)
      when "Between" then between(body, context)
      when "InList" then in_list(body, context)
      when "Like", "ILike" then like(body, context, ci: key == "ILike")
      else opaque(ast, context)
      end
    end

    def binary(body, context)
      op = body.fetch("op")
      return boolean(op.downcase, body, context) if %w[And Or].include?(op)
      return opaque({ "BinaryOp" => body }, context) unless CMP_OPS.key?(op)
      comparison(op, body, context)
    end

    def boolean(op, body, context)
      { "op" => op, "children" => [node(body.fetch("left"), context),
                                   node(body.fetch("right"), context)] }
    end

    # Normalized to column-on-left; a flipped comparison mirrors the
    # operator. Column-to-column or literal-to-literal comparisons and any
    # non-simple side go opaque.
    def comparison(op, body, context)
      left, right = body.fetch("left"), body.fetch("right")
      if (col = column(left, context))
        val = value(right, context)
        return { "op" => "cmp", "cmp" => CMP_OPS[op], "col" => col, "v" => val } if val
      elsif (col = column(right, context)) && (val = value(left, context))
        return { "op" => "cmp", "cmp" => mirror(CMP_OPS[op]), "col" => col, "v" => val }
      end
      opaque({ "BinaryOp" => body }, context)
    end

    def mirror(cmp)
      { "lt" => "gt", "lte" => "gte", "gt" => "lt", "gte" => "lte" }.fetch(cmp, cmp)
    end

    def unary(body, context)
      return opaque({ "UnaryOp" => body }, context) unless body.fetch("op") == "Not"
      { "op" => "not", "child" => node(body.fetch("expr"), context) }
    end

    def null_node(body, context)
      col = column(body.fetch("expr"), context)
      return opaque({ "IsNull" => body }, context) unless col
      { "op" => "null", "col" => col, "negated" => body.fetch("negated") }
    end

    def between(body, context)
      col = column(body.fetch("expr"), context)
      low = value(body.fetch("low"), context)
      high = value(body.fetch("high"), context)
      return opaque({ "Between" => body }, context) unless col && low && high
      { "op" => "between", "col" => col, "low" => low, "high" => high,
        "negated" => body.fetch("negated") }
    end

    def in_list(body, context)
      col = column(body.fetch("expr"), context)
      list = body.fetch("list").map { |item| value(item, context) }
      return opaque({ "InList" => body }, context) unless col && list.all?
      { "op" => "in", "col" => col, "list" => list, "negated" => body.fetch("negated") }
    end

    def like(body, context, ci:)
      col = column(body.fetch("expr"), context)
      pattern = value(body.fetch("pattern"), context)
      return opaque({ "Like" => body }, context) unless col && pattern && body["escape"].nil?
      { "op" => "like", "col" => col, "pattern" => pattern, "ci" => ci,
        "negated" => body.fetch("negated") }
    end

    # A recognized column of the fragment's own table (bare, own-table
    # qualified, or alias-of-own-table qualified). A column of a covered
    # joined table returns nil — the caller's branch goes opaque (UNKNOWN),
    # which is safe because the joined table is a table-level dependency
    # anyway. A foreign qualifier aborts the whole compile — attribution
    # would be a guess.
    def column(ast, context)
      body = ast.is_a?(Hash) ? ast["Column"] : nil
      return nil unless body
      qualifier = body["table"]
      if qualifier && !own_table?(qualifier, context)
        raise ForeignTable, "column qualified with #{qualifier}" unless covered?(qualifier, context)
        return nil
      end
      name = body.fetch("name")
      context[:columns] << name
      name
    end

    def own_table?(qualifier, context)
      qualifier == context[:table] || context[:aliases][qualifier] == context[:table]
    end

    # A joined table (or an alias of one, or an aliased subquery) that the
    # relation analysis already records as a table-level dependency.
    def covered?(qualifier, context)
      return true if context[:covered].include?(qualifier)
      target = context[:aliases][qualifier]
      target == :scope || context[:covered].include?(target.to_s)
    end

    def value(ast, context)
      return nil unless ast.is_a?(Hash)
      key, body = ast.first
      case key
      when "StringLiteral" then { "lit" => body }
      when "Number" then { "lit" => numeric(body) }
      when "Boolean" then { "lit" => body }
      when "Null" then { "lit" => nil }
      when "Parameter" then bind_slot(context)
      end
    end

    def numeric(text)
      text.include?(".") ? Float(text) : Integer(text)
    rescue ArgumentError
      text
    end

    def bind_slot(context)
      context[:binds] = (context[:binds] || 0) + 1
      { "bind" => context[:binds] - 1 }
    end

    # Unsupported constructs (functions, casts, subqueries, JSON operators)
    # stay matchable: harvest every column reference underneath, evaluate to
    # UNKNOWN. Foreign-table references still abort via column().
    def opaque(ast, context)
      columns = []
      harvest_columns(ast, context, columns)
      context[:columns].concat(columns)
      context[:opaque] = true
      { "op" => "opaque", "columns" => columns.uniq }
    end

    SUBQUERY_KEYS = %w[Subquery Select Query].freeze

    def harvest_columns(ast, context, acc)
      case ast
      when Hash
        raise ForeignTable, "subquery inside fragment" if SUBQUERY_KEYS.any? { |k| ast.key?(k) }
        if ast.key?("Column")
          harvest_column(ast["Column"], context, acc)
        else
          ast.each_value { |v| harvest_columns(v, context, acc) }
        end
      when Array
        ast.each { |v| harvest_columns(v, context, acc) }
      end
    end

    def harvest_column(body, context, acc)
      qualifier = body["table"]
      if qualifier && !own_table?(qualifier, context)
        raise ForeignTable, "column qualified with #{qualifier}" unless covered?(qualifier, context)
      else
        acc << body.fetch("name")
      end
    end

    def plain_value(bind)
      case bind
      when Numeric, String, TrueClass, FalseClass, NilClass then bind
      else bind.to_s
      end
    end

    def collect_literals(tree, acc)
      case tree
      when Hash
        acc << tree["lit"] if tree.key?("lit") && !tree["lit"].nil?
        tree.each_value { |v| collect_literals(v, acc) }
      when Array
        tree.each { |v| collect_literals(v, acc) }
      end
    end

    # --- evaluation helpers --------------------------------------------------

    def eval_node(tree, table, attrs, binds)
      case tree["op"]
      when "and", "or" then eval_boolean(tree, table, attrs, binds)
      when "not" then invert(eval_node(tree["child"], table, attrs, binds))
      when "cmp" then eval_cmp(tree, table, attrs, binds)
      when "null" then eval_null(tree, attrs)
      when "between" then eval_between(tree, table, attrs, binds)
      when "in" then eval_in(tree, table, attrs, binds)
      when "like" then eval_like(tree, table, attrs, binds)
      else nil
      end
    end

    def eval_boolean(tree, table, attrs, binds)
      results = tree["children"].map { |c| eval_node(c, table, attrs, binds) }
      tree["op"] == "and" ? three_valued_all(results) : three_valued_any(results)
    end

    def three_valued_all(results)
      return false if results.any? { |r| r == false }
      results.all? ? true : nil
    end

    def three_valued_any(results)
      return true if results.any? { |r| r == true }
      results.any?(&:nil?) ? nil : false
    end

    def invert(result) = result.nil? ? nil : !result

    # SQL comparison: NULL on either side is UNKNOWN; incomparable casts
    # are UNKNOWN (never a crash, never a false certainty).
    def eval_cmp(tree, table, attrs, binds)
      lhs, rhs = sides(tree["col"], tree["v"], table, attrs, binds)
      return lhs if lhs.nil? || rhs.nil? # unknown column or NULL value
      ordering = lhs <=> rhs
      return nil if ordering.nil?
      case tree["cmp"]
      when "eq" then ordering.zero?
      when "ne" then !ordering.zero?
      when "lt" then ordering.negative?
      when "lte" then !ordering.positive?
      when "gt" then ordering.positive?
      when "gte" then !ordering.negative?
      end
    end

    def sides(col, val, table, attrs, binds)
      return [nil, nil] unless attrs.key?(col)
      lhs = Coercion.cast(table, col, attrs[col])
      rhs = Coercion.cast(table, col, resolve(val, binds))
      return [nil, nil] if lhs.nil? || rhs.nil?
      [lhs, rhs]
    end

    def eval_null(tree, attrs)
      col = tree["col"]
      return nil unless attrs.key?(col)
      attrs[col].nil? ^ tree["negated"]
    end

    def eval_between(tree, table, attrs, binds)
      low = eval_cmp({ "cmp" => "gte", "col" => tree["col"], "v" => tree["low"] }, table, attrs, binds)
      high = eval_cmp({ "cmp" => "lte", "col" => tree["col"], "v" => tree["high"] }, table, attrs, binds)
      result = three_valued_all([low, high])
      tree["negated"] ? invert(result) : result
    end

    def eval_in(tree, table, attrs, binds)
      results = tree["list"].map do |item|
        eval_cmp({ "cmp" => "eq", "col" => tree["col"], "v" => item }, table, attrs, binds)
      end
      result = three_valued_any(results)
      tree["negated"] ? invert(result) : result
    end

    def eval_like(tree, table, attrs, binds)
      col = tree["col"]
      return nil unless attrs.key?(col)
      subject = attrs[col]
      pattern = resolve(tree["pattern"], binds)
      return nil if subject.nil? || pattern.nil?
      regex = like_regex(pattern.to_s, tree["ci"])
      result = regex.match?(subject.to_s)
      tree["negated"] ? !result : result
    end

    def like_regex(pattern, case_insensitive)
      source = pattern.chars.map do |char|
        case char
        when "%" then ".*"
        when "_" then "."
        else Regexp.escape(char)
        end
      end.join
      Regexp.new("\\A#{source}\\z", case_insensitive ? Regexp::IGNORECASE : 0)
    end

    def resolve(val, binds)
      val.key?("bind") ? binds[val["bind"]] : val["lit"]
    end
  end
end
