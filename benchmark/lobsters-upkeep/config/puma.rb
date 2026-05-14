threads_count = ENV.fetch("RAILS_MAX_THREADS", 5)
threads threads_count, threads_count

workers ENV.fetch("WEB_CONCURRENCY", 2)

plugin :tmp_restart
plugin :upkeep if ENV["BENCH"] == "1"
