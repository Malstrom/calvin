# frozen_string_literal: true
# Helper dei test di Calvin.
#
# Carica solo ciò che serve alle unit: boot.rb richiede octokit e le costanti di ambiente
# (GITHUB_REPOSITORY, MISTRAL_API_KEY) che qui non esistono, quindi vengono impostate a
# valori finti prima del require. Nessun test in questa suite fa I/O di rete.

ENV["GITHUB_REPOSITORY"] ||= "Malstrom/calvin-test"
ENV["GITHUB_TOKEN"]      ||= "test-token"
ENV["MISTRAL_API_KEY"]   ||= "test-key"
ENV.delete("CALVIN_VALIDATION_LEVEL")
ENV.delete("CALVIN_DRY_RUN")

require "minitest/autorun"
require_relative "../lib/boot"

module Calvin
  module TestSupport
    FIXTURES = File.expand_path("fixtures", __dir__)

    def fixture(name)
      File.read(File.join(FIXTURES, name), encoding: "UTF-8")
    end

    # Doppio minimale di un'issue Octokit.
    Issue = Struct.new(:number, :title, :body, :labels, keyword_init: true) do
      def self.build(number: 1, title: "Titolo task", body: "Descrizione", labels: [])
        new(number: number, title: title, body: body, labels: labels)
      end
    end

    # Doppio di lettura del repo: risponde all'interfaccia usata da ContextBuilder,
    # Validator e RepoReader senza toccare la rete.
    class FakeReader
      def initialize(files: {}, dirs: {})
        @files = files
        @dirs  = dirs
      end

      def get_file_content(path, ref: nil) = @files[path]

      def list_directory(path) = @dirs.fetch(path, [])

      def grep_files(_pattern, _path) = "ERROR: no matches"
    end

    # Workspace su directory temporanea — usato dai test del Validator e di Workspace.
    def with_workspace(files: {}, repo_root: "")
      Dir.mktmpdir("calvin-test-ws-") do |dir|
        root = repo_root.empty? ? dir : File.join(dir, repo_root)
        FileUtils.mkdir_p(root)
        files.each do |path, content|
          full = File.join(root, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
        yield Calvin::Workspace.new(repo_root: repo_root, target_path: dir)
      end
    end
  end
end

require "tmpdir"
require "fileutils"

class Minitest::Test
  include Calvin::TestSupport
end
