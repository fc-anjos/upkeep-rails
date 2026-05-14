if ENV["BENCH"] == "1"
  require Rails.root.join("..", "shared", "bench_metrics").expand_path
  BenchMetrics.install
end
