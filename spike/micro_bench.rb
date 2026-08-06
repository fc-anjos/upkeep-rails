# frozen_string_literal: true

# Controller-free micro-benchmark: compile the _card template through
# Herb::Engine plain vs with the ProvSpike visitor, then execute the compiled
# Ruby directly. Isolates pure injection overhead from all Rails plumbing.
#
# Run: ruby spike/micro_bench.rb

ENV["DATABASE_URL"] = "sqlite3::memory:"
require "action_view"
require "active_record"
require "herb"
require "digest"
require_relative "lib/prov_spike"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:users) { |t| t.string :name }
  create_table(:cards) do |t|
    t.string :title
    t.integer :owner_id
  end
end

class User < ActiveRecord::Base; end

class Card < ActiveRecord::Base
  belongs_to :owner, class_name: "User"
end

owner = User.create!(name: "Bob")
card = Card.create!(title: "Ship it", owner: owner)
card.owner # warm the association cache so DB cost doesn't pollute the loop

source = File.read(File.expand_path("views/boards/_card.html.erb", __dir__))

compile = lambda { |instrumented|
  visitors = []
  if instrumented
    Thread.current[:prov_spike_template] = { file: "boards/_card.html.erb",
                                             digest: Digest::SHA256.hexdigest(source)[0, 12] }
    visitors << ProvSpike::Visitor.new
  end
  src = Herb::Engine.new(source,
                         bufvar: "@output_buffer",
                         preamble: "",
                         postamble: "@output_buffer",
                         escapefunc: "",
                         visitors: visitors).src
  Thread.current[:prov_spike_template] = nil
  src
}

plain_src = compile.call(false)
instr_src = compile.call(true)

context = Class.new do
  def run(card, src_lambda)
    src_lambda.call(self, card)
  end
end.new

build = lambda { |src|
  eval("lambda { |ctx, card| ctx.instance_eval { @output_buffer = ActionView::OutputBuffer.new; #{src} } }") # rubocop:disable Security/Eval
}

plain_fn = build.call(plain_src)
instr_fn = build.call(instr_src)

# Verify identical rendered content (modulo whitespace).
a = plain_fn.call(context, card).to_s
b = instr_fn.call(context, card).to_s
raise "content mismatch!\n#{a.inspect}\n#{b.inspect}" unless a.gsub(/\s+/, " ") == b.gsub(/\s+/, " ")

N = 50_000

bench = lambda { |fn|
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  N.times { fn.call(context, card) }
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000_000.0 / N
}

# Order-alternated, 6 rounds.
plain_us = []
instr_off_us = []
instr_on_us = []

6.times do |i|
  legs = [
    [plain_us, plain_fn, nil],
    [instr_off_us, instr_fn, nil],
    [instr_on_us, instr_fn, :capture],
  ]
  legs.reverse! if i.odd?
  legs.each do |bucket, fn, capture|
    ProvSpike::Runtime.record! if capture
    bucket << bench.call(fn)
    ProvSpike::Runtime.finish! if capture
  end
end

avg = ->(arr) { arr.sum / arr.size }

puts "template: boards/_card.html.erb (3 instrumented nodes: li element + 2 expressions)"
puts format("plain compiled:               %8.3f us/render", avg.call(plain_us))
puts format("instrumented, capture OFF:    %8.3f us/render  (%+.3f)", avg.call(instr_off_us), avg.call(instr_off_us) - avg.call(plain_us))
puts format("instrumented, capture ON:     %8.3f us/render  (%+.3f)", avg.call(instr_on_us), avg.call(instr_on_us) - avg.call(plain_us))
puts format("per-node cost, capture OFF:   %8.3f us", (avg.call(instr_off_us) - avg.call(plain_us)) / 3)
puts format("per-node cost, capture ON:    %8.3f us", (avg.call(instr_on_us) - avg.call(plain_us)) / 3)
