# frozen_string_literal: true

# Standalone repro: whitespace behavior when a visitor INJECTS `<% %>` code
# nodes adjacent to `<%= %>` expression nodes, herb latest (0.10.3).
#
# Question it answers: is the whitespace delta a Herb bug, or inherent ERB
# trim semantics that any tag insertion (typed or injected) would trigger?
#
# Four legs, same logical template:
#   A. herb, plain source                      "a\n<%= 1 %>\nb\n"
#   B. herb, plain source + VISITOR-injected `<% :probe %>` around the expr
#   C. herb, tags typed literally in source    "a\n<% :probe %><%= 1 %><% :probe %>\nb\n"
#   D. erubi, same literal source as C
#
# If B == C, injection is exactly equivalent to typing the tags (no engine
# bug — the delta is ERB's code-line newline trimming, which any inserted
# tag triggers). If C ~= D, herb matches erubi semantics for the literal
# form. Run: ruby trim_repro.rb

require "herb"
require "erubi"

SOURCE = "a\n<%= 1 %>\nb\n"
LITERAL = "a\n<% :probe %><%= 1 %><% :probe %>\nb\n"

class InjectProbes < Herb::Visitor
  def visit_document_node(node)
    dummy_loc = Herb::Location.from(0, 0, 0, 0)
    dummy_range = Herb::Range.from(0, 0)
    make_token = ->(type, value) { Herb::Token.new(value.dup, dummy_range, dummy_loc, type.to_s) }
    code_node = lambda {
      Herb::AST::ERBContentNode.new(
        "ERBContentNode", dummy_loc, [],
        make_token.call(:tag_opening, "<%"),
        make_token.call(:content, " :probe "),
        make_token.call(:tag_closing, "%>"),
        nil, true, true, nil
      )
    }

    rewritten = []
    node.children.each do |child|
      is_expr = child.class.name.end_with?("ERBContentNode") &&
                child.tag_opening&.value.to_s.include?("=")
      if is_expr
        rewritten << code_node.call << child << code_node.call
      else
        rewritten << child
      end
    end
    node.children.replace(rewritten)
    nil
  end
end

def herb_compile(source, visitors: [])
  Herb::Engine.new(source, bufvar: "@b", preamble: "", postamble: "@b",
                          escapefunc: "", freeze_template_literals: false,
                          visitors: visitors).src
end

def run(src)
  binding.eval("@b = +''; #{src}")
end

a = run(herb_compile(SOURCE))
b = run(herb_compile(SOURCE, visitors: [InjectProbes.new]))
c = run(herb_compile(LITERAL))
d = run(Erubi::Engine.new(LITERAL, bufvar: "@b", preamble: "@b = +'';", postamble: "@b").src)

puts "herb version: #{Herb::VERSION rescue Gem.loaded_specs["herb"]&.version}"
puts "A herb plain:            #{a.inspect}"
puts "B herb visitor-injected: #{b.inspect}"
puts "C herb literal tags:     #{c.inspect}"
puts "D erubi literal tags:    #{d.inspect}"
puts
puts "B == A (injection preserves output):     #{b == a}"
puts "B == C (injection == typing the tags):   #{b == c}"
puts "C == D (herb matches erubi on literal):  #{c == d}"

