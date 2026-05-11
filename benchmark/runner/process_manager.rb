# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Upkeep
  module Benchmark
    module Runner
      class ProcessManager
        def stop_pidfile_process(pidfile, expected_cwd, label)
          return unless File.exist?(pidfile)

          pid = File.read(pidfile).scan(/\d+/).first&.to_i
          FileUtils.rm_f(pidfile)
          return unless pid && process_alive?(pid)
          return if expected_cwd && process_cwd(pid) != expected_cwd

          puts "Cleaning stale #{label}: #{describe_process(pid)}"
          stop_pid_list([ pid ])
        end

        def stop_owned_pattern_processes(pattern, expected_cwd, label)
          pids = `pgrep -f #{Shellwords.escape(pattern)} 2>/dev/null`.split.map(&:to_i)
          owned = pids.select { |pid| expected_cwd.nil? || process_cwd(pid) == expected_cwd }
          return if owned.empty?

          puts "Cleaning stale #{label}: #{owned.join(" ")}"
          stop_pid_list(owned)
        end

        def assert_listener_clear(port, label)
          pids = `lsof -tiTCP:#{port} -sTCP:LISTEN 2>/dev/null`.split.map(&:to_i)
          return if pids.empty?

          warn "ERROR: #{label} requires TCP port #{port}, but a listener already exists."
          pids.each { |pid| warn "  #{describe_process(pid)}" }
          exit 1
        end

        def process_alive?(pid)
          Process.kill(0, pid)
          true
        rescue Errno::ESRCH
          false
        end

        def process_cwd(pid)
          `lsof -a -p #{pid} -d cwd -Fn 2>/dev/null`.lines.grep(/^n/).first&.delete_prefix("n")&.strip
        end

        def describe_process(pid)
          command = `ps -o command= -p #{pid} 2>/dev/null`.strip
          "pid=#{pid} cwd=#{process_cwd(pid) || "<unknown>"} cmd=#{command.empty? ? "<unknown>" : command}"
        end

        private
          def stop_pid_list(pids)
            pids.each { |pid| begin
                                Process.kill("TERM", pid)
                              rescue
                                nil
                              end }
            pids.each do |pid|
              10.times do
                break unless process_alive?(pid)
                sleep 0.5
              end
              begin
                Process.kill("KILL", pid)
              rescue
                nil
              end
            end
          end
      end
    end
  end
end
