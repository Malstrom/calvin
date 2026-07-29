#!/usr/bin/env ruby
# frozen_string_literal: true
# Eval harness — misura la qualità di Calvin su un set di issue congelate.
#
# Perché esiste: il repo ha una cinquantina di commit, molti sui prompt, tutti validati a
# occhio su un singolo run. Senza una baseline riproducibile non è possibile sapere quali
# modifiche abbiano migliorato qualcosa. Questo script produce quel numero.
#
# Usage:
#   ruby bin/eval.rb --suite data/evals/suite.yml
#   ruby bin/eval.rb --suite data/evals/suite.yml --issues 101,104 --label baseline
#
# Il run è sempre in dry-run (nessun commit, nessuna PR): CALVIN_DRY_RUN viene forzato
# qui, non serve impostarlo a mano.
#
# Formato della suite (YAML):
#
#   target_repo: Malstrom/synca
#   target_sha: 9f3c1ab            # opzionale: SHA a cui pinnare il clone locale
#   validation_level: full
#   issues:
#     - number: 101
#       expect_files:              # opzionale — path attesi nel file_plan finale
#         - app/services/magic_link_service.rb
#
# Output:
#   - tabella a schermo
#   - data/evals/<label>-<timestamp>.json con una riga per issue
#
# Confronto fra due configurazioni: lanciare due volte con --label diverse e
# confrontare i due JSON.

require "optparse"
require "json"
require "yaml"
require "time"
require "fileutils"

ENV["CALVIN_DRY_RUN"] = "true"

require_relative "../lib/boot"

# Quanti dei path attesi sono stati effettivamente prodotti (nil se la suite non li dichiara).
def expected_hit(expected, produced)
  return nil if expected.nil? || Array(expected).empty?

  wanted = Array(expected).map(&:to_s)
  "#{(wanted & produced).size}/#{wanted.size}"
end

options = { label: "eval" }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/eval.rb --suite data/evals/suite.yml [--issues 1,2] [--label baseline]"
  opts.on("--suite PATH",  "YAML con la suite di issue")            { |v| options[:suite]  = v }
  opts.on("--issues LIST", "Sottoinsieme di issue (numeri, CSV)")   { |v| options[:issues] = v.split(",").map(&:strip).map(&:to_i) }
  opts.on("--label NAME",  "Etichetta del run (default: eval)")     { |v| options[:label]  = v }
  opts.on("--level LEVEL", "Override validation level static|full") { |v| options[:level]  = v }
end.parse!

abort "--suite è obbligatorio" unless options[:suite]
abort "suite non trovata: #{options[:suite]}" unless File.exist?(options[:suite])

suite = YAML.load_file(options[:suite], symbolize_names: true)
cases = Array(suite[:issues])
cases = cases.select { |c| options[:issues].include?(c[:number]) } if options[:issues]
abort "nessuna issue da eseguire" if cases.empty?

level = options[:level] || suite[:validation_level] || "static"
ENV["CALVIN_VALIDATION_LEVEL"] = level

Calvin.banner("EVAL  •  #{cases.size} issue  •  level=#{level}", emoji: "📐")
Calvin::LOG.warn "target_sha #{suite[:target_sha]} — verifica che il clone locale sia su questo commit" if suite[:target_sha]

# ── esecuzione ────────────────────────────────────────────────────────────────────────
results = cases.map do |kase|
  number = kase[:number]
  Calvin.section("issue ##{number}")
  started = Time.now

  row = { issue: number, started_at: started.utc.iso8601 }

  begin
    github    = Calvin::GitHubClient.new
    issue     = github.fetch_issue(number)
    labels    = issue.labels.map(&:name)
    repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""

    scoped    = Calvin::GitHubClient.new(repo_root: repo_root)
    workspace = Calvin::Workspace.new(repo_root: repo_root)
    stack     = labels.include?("flutter") ? "flutter" : "rails"

    result = Calvin::ExploreFlow.new.call(
      issue: issue, github: scoped, stack: stack,
      workspace: workspace, mistral: Calvin::MistralClient.new
    )

    if result.success?
      value = result.value!
      paths = Array(value.files).map { |f| f[:path] }

      row.merge!(
        outcome:          value.meta(:validation_ok) ? "green" : "red",
        validation_stage: value.meta(:validation_stage).to_s,
        repair_attempts:  value.meta(:repair_attempts),
        explore_turns:    value.meta(:explore_turns),
        files:            paths,
        files_count:      paths.size,
        prompt_tokens:    value.usage&.dig("prompt_tokens"),
        completion_tokens: value.usage&.dig("completion_tokens"),
        expected_files_hit: expected_hit(kase[:expect_files], paths)
      )
    else
      err = result.failure
      row.merge!(outcome: "failure", failed_step: err[:step].to_s, error: err[:error].to_s[0, 300])
    end
  rescue => e
    row.merge!(outcome: "error", error: "#{e.class}: #{e.message}")
  end

  row[:seconds] = (Time.now - started).round(1)
  row
end

# ── report ────────────────────────────────────────────────────────────────────────────
rows = results.map do |r|
  [
    "##{r[:issue]}",
    r[:outcome],
    r[:validation_stage].to_s.empty? ? "—" : r[:validation_stage],
    r[:repair_attempts] || "—",
    r[:explore_turns] || "—",
    r[:files_count] || 0,
    r[:expected_files_hit] || "—",
    "#{r[:seconds]}s"
  ]
end

header = %w[issue outcome gate repair turns files expected time]
widths = header.each_with_index.map { |h, i| [h.length, *rows.map { |r| r[i].to_s.length }].max }

puts
puts header.each_with_index.map { |h, i| h.ljust(widths[i]) }.join("  ")
puts widths.map { |w| "-" * w }.join("  ")
rows.each { |r| puts r.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ") }
puts

green = results.count { |r| r[:outcome] == "green" }
Calvin.flow_summary([
  ["issue eseguite", results.size],
  ["verdi",          "#{green}/#{results.size} (#{(green * 100.0 / results.size).round}%)"],
  ["repair medi",    format("%.1f", results.sum { |r| r[:repair_attempts].to_i } / results.size.to_f)],
  ["token totali",   results.sum { |r| r[:prompt_tokens].to_i + r[:completion_tokens].to_i }],
  ["level",          level]
])

# ── persistenza ───────────────────────────────────────────────────────────────────────
out_dir = File.expand_path("../data/evals", __dir__)
FileUtils.mkdir_p(out_dir)
out_path = File.join(out_dir, "#{options[:label]}-#{Time.now.utc.strftime('%Y%m%d%H%M%S')}.json")
File.write(out_path, JSON.pretty_generate(
  label:            options[:label],
  ran_at:           Time.now.utc.iso8601,
  model:            Calvin::MODEL,
  validation_level: level,
  target_sha:       suite[:target_sha],
  green:            green,
  total:            results.size,
  results:          results
))

Calvin.done "risultati salvati in #{out_path}"
exit(green == results.size ? 0 : 1)
