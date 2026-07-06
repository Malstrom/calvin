# frozen_string_literal: true
# Calvin::RubocopAutocorrect — thin wrapper su RubocopRunner.
#
# Mantiene la stessa firma pubblica usata da PostSteps:
#   Calvin::RubocopAutocorrect.run(files:, branch:, github:)
#
# Delegato a RubocopRunner per la logica core. Se ci sono file corretti,
# li committa sul branch come commit separato (non bloccante).

module Calvin
  module RubocopAutocorrect
    def self.run(files:, branch:, github:)
      result = Calvin::RubocopRunner.run(files: files, github: github)

      case result[:status]
      when :noop
        Calvin::LOG.info "RubocopAutocorrect: nessun file .rb — skip"
        return
      when :error
        # RubocopRunner ha già loggato — non blocchiamo il flow
        return
      end

      corrected = result[:corrected]
      if corrected.empty?
        Calvin::LOG.info "RubocopAutocorrect: nessuna correzione necessaria"
        return
      end

      Calvin::LOG.info "RubocopAutocorrect: #{corrected.size} file(s) corretti — commit su #{branch}"
      github.commit_files_atomically(
        corrected,
        message: "chore: rubocop autocorrect",
        branch:  branch
      )
    rescue => e
      Calvin::LOG.warn "RubocopAutocorrect FAILED (non bloccante): #{e.class} — #{e.message}"
    end
  end
end
