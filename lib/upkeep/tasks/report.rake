# rails upkeep:report — static liveness map from the persisted store.
# UPKEEP_REPORT_JSON=1 emits the same map as JSON for tooling/CI.
namespace :upkeep do
  desc "Liveness map: every known page/cohort, tier, surfaces, degradations"
  task report: :environment do
    report = Upkeep::Report.build
    if ENV["UPKEEP_REPORT_JSON"] == "1"
      puts JSON.pretty_generate(report.as_json)
    else
      puts report.to_text
    end
  end
end
