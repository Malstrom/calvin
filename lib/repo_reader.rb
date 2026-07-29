# frozen_string_literal: true
# Calvin::RepoReader — sorgente unica di lettura del repo target.
#
# Espone la stessa interfaccia di lettura di GitHubClient (get_file_content, list_directory,
# grep_files) ma serve le richieste dal clone locale quando disponibile, ricadendo sulla
# Contents API solo se il clone manca o se il file non è nel working tree.
#
# Perché esiste: il ReActLoop e il TestWriter parlano già questo protocollo. Introducendo
# l'adapter, passare al filesystem non richiede di toccare la logica dei tool — cambia solo
# chi risponde.
#
# Uso:
#   reader = Calvin::RepoReader.new(workspace: ws, github: github)
#   reader.source          # => :workspace | :api
#   reader.get_file_content("app/models/user.rb")

module Calvin
  class RepoReader
    def initialize(workspace:, github:)
      @workspace = workspace
      @github    = github
      @local     = workspace&.available? || false
    end

    attr_reader :workspace, :github

    def local? = @local

    def source = @local ? :workspace : :api

    def get_file_content(path, ref: nil)
      # Con un ref esplicito serve l'API: il clone è su un solo commit.
      return @github.get_file_content(path, ref: ref) if ref || !@local

      @workspace.read(path) || @github.get_file_content(path)
    end

    def list_directory(path)
      return @github.list_directory(path) unless @local

      entries = @workspace.list(path)
      entries.empty? ? @github.list_directory(path) : entries
    end

    def grep_files(pattern, path)
      return @github.grep_files(pattern, path) unless @local

      @workspace.grep(pattern, path)
    end
  end
end
