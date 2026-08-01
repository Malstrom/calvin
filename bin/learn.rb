#!/usr/bin/env ruby
# frozen_string_literal: true
# Report degli errori che Calvin ripete — la sostituzione automatica del loop manuale
# "un LLM estrae regole da un diff → commento con checkbox → approvazione → embedding".
#
# Quel meccanismo chiedeva di validare un'affermazione generalizzata da un solo diff.
# Qui l'evidenza arriva dai run: ogni gate rosso registrato da RepairLoop dice cosa Calvin
# ha sbagliato e se è riuscito a correggersi. Aggregato, diventa una lista di priorità.
#
# Usage:
#   ruby bin/learn.rb                       # ultimi 30 giorni, repo da GITHUB_REPOSITORY
#   ruby bin/learn.rb --days 90 --min 5
#   ruby bin/learn.rb --all-repos           # pattern comuni a tutti i progetti
#   ruby bin/learn.rb --json                # output machine-readable
#
# Come leggere l'output:
#
#   PREVIENI  frequente e quasi sempre auto-riparato. Calvin sa risolverlo, ma solo dopo
#             aver sbagliato: ogni occorrenza costa una chiamata di repair. Va reso
#             impossibile con un gate in lib/validator.rb, o evidente con un esempio nel
#             prompt implement.
#   UMANO     frequente e quasi mai riparato. Il repair non ce la fa: il vincolo è mal
#             specificato o è un limite del modello. È l'unica riga che merita la tua
#             attenzione diretta.
#   OSSERVA   esito misto — tienilo d'occhio, non agire ancora.
#
# La regola operativa: prima rendere l'errore impossibile, poi renderlo evidente con un
# esempio. Il testo nel prompt è l'ultima opzione, non la prima.

require "optparse"
require "json"
require_relative "../lib/boot"

VERDICT_LABEL = {
  prevent: "PREVIENI",
  human:   "UMANO",
  watch:   "OSSERVA",
  noise:   "rumore"
}.freeze

# Il report deve dire cosa fare, non solo contare.
def suggestion(verdict, entry)
  case verdict
  when :prevent
    case entry[:gate]
    when "rubocop"
      "→ cop non autocorreggibile: mettilo come esempio nel prompt implement, o valuta di disabilitarlo nel .rubocop.yml del target se non lo vuoi"
    when "structural"
      "→ il gate esiste e funziona: rendi il vincolo esplicito nel prompt implement, così il modello non ci arriva per tentativi"
    else
      "→ candidato a gate deterministico in lib/validator.rb (con unit test), oppure a esempio nel prompt"
    end
  when :human
    "→ il repair non lo risolve: vincolo mal specificato o limite del modello. Serve una tua decisione (gate? esempio? riformulare la task?)"
  else
    "→ esito misto: rileggi gli excerpt prima di agire"
  end
end

options = { days: 30, min: 3, all_repos: false, json: false }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/learn.rb [--days N] [--min N] [--all-repos] [--json]"
  opts.on("--days N",   Integer, "Finestra temporale in giorni (default 30)") { |v| options[:days]      = v }
  opts.on("--min N",    Integer, "Occorrenze minime per non essere rumore (default 3)") { |v| options[:min] = v }
  opts.on("--all-repos",         "Aggrega su tutti i progetti")               { options[:all_repos] = true }
  opts.on("--json",              "Output JSON invece della tabella")          { options[:json]      = true }
end.parse!

unless Calvin::LearningStore.configured?
  abort "SUPABASE_URL e SUPABASE_SERVICE_KEY non impostate — nessun dato da aggregare."
end

scope_label = options[:all_repos] ? "tutti i progetti" : Calvin::REPO
entries     = Calvin::LearningStore.aggregate(since_days: options[:days], all_repos: options[:all_repos])

if options[:json]
  puts JSON.pretty_generate(
    repo:       options[:all_repos] ? "*" : Calvin::REPO,
    since_days: options[:days],
    entries:    entries.map { |e| e.merge(verdict: Calvin::LearningStore.classify(e, min_occurrences: options[:min])) }
  )
  exit 0
end

Calvin.banner("LEARN  •  #{scope_label}  •  ultimi #{options[:days]}g", emoji: "🧠")

if entries.empty?
  Calvin::LOG.info "Nessun evento di repair registrato nella finestra — o Calvin non ha sbagliato, o i run non hanno raggiunto la validazione."
  exit 0
end

grouped = entries.group_by { |e| Calvin::LearningStore.classify(e, min_occurrences: options[:min]) }

%i[prevent human watch].each do |verdict|
  rows = grouped[verdict]
  next if rows.nil? || rows.empty?

  Calvin.section("#{VERDICT_LABEL[verdict]} (#{rows.size})")

  rows.each do |e|
    rate = e[:occurrences].positive? ? (e[:fixed_count] * 100.0 / e[:occurrences]).round : 0
    puts "  #{e[:signature]}"
    puts "    #{e[:occurrences]}× · riparato #{e[:fixed_count]}/#{e[:occurrences]} (#{rate}%)#{e[:scope] ? " · scope #{e[:scope]}" : ''}"
    puts "    #{e[:paths].join(', ')}" if e[:paths].any?
    puts "    #{suggestion(verdict, e)}"
    puts
  end
end

noise = grouped[:noise]&.size || 0
Calvin.flow_summary([
  ["firme distinte",  entries.size],
  ["da prevenire",    grouped[:prevent]&.size || 0],
  ["da decidere",     grouped[:human]&.size   || 0],
  ["da osservare",    grouped[:watch]&.size   || 0],
  ["rumore (<#{options[:min]}×)", noise],
  ["eventi totali",   entries.sum { |e| e[:occurrences] }]
])
