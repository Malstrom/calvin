# frozen_string_literal: true
# RubocopAutocorrect — modulo eliminato.
# L'autocorrect è ora gestito direttamente in CommitAndPr#commit_and_open_pr
# tramite write_files_to_disk + rubocop --autocorrect + reread.
# Questo file è mantenuto vuoto per compatibilità con require_relative esistenti.
module RubocopAutocorrect
end
