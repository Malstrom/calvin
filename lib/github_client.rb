# frozen_string_literal: true
# Wrapper Octokit. Centralizza tutte le chiamate GitHub API.
#
# repo_root: prefisso applicato a tutti i path di file (es. "backend/api").
# Viene determinato dalle label dell'issue tramite REPO_ROOTS in calvin.rb.

require "base64"

module Calvin
  class GitHubClient
    def initialize(repo_root: "")
      @client    = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
      @repo_root = repo_root
    end

    def fetch_issue(number)
      @client.issue(REPO, number)
    end

    # Ritorna tutti i commenti dell'issue
    def issue_comments(issue)
      @client.issue_comments(REPO, issue.number)
    end

    # Aggiorna o crea il commento di stato Calvin sull'issue
    def post_status(issue, msg)
      marker   = "<!-- calvin-status -->"
      body     = "#{marker}\n#{msg}"
      existing = @client.issue_comments(REPO, issue.number)
                        .find { |c| c.body.start_with?(marker) }
      if existing
        @client.update_comment(REPO, existing.id, body)
      else
        @client.add_comment(REPO, issue.number, body)
      end
    end

    # Posta un commento su una PR (pr_number == issue_number in GitHub)
    def post_pr_comment(pr_number, body)
      @client.add_comment(REPO, pr_number, body)
    end

    # Aggiunge una label a una PR/issue
    def add_label(number, label)
      @client.add_labels_to_an_issue(REPO, number, [label])
    end

    # Rimuove una label da una PR/issue
    def remove_label(pr_number, label)
      @client.remove_label(REPO, pr_number, label)
    end

    # Ritorna il contenuto di un file o nil se non esiste.
    # ref: branch, tag o commit SHA (default: branch default del repo).
    # Applica repo_root al path se configurato.
    def get_file_content(path, ref: nil)
      opts    = ref ? { path: full_path(path), ref: ref } : { path: full_path(path) }
      content = @client.contents(REPO, **opts)
      Base64.decode64(content.content)
    rescue Octokit::NotFound
      nil
    end

    # Lista i nomi dei file/directory in un path.
    # Path vuoto ("") = root del repo.
    # Applica repo_root se configurato.
    # Ritorna array di stringhe: ["app", "config", "db", ...]
    def list_directory(path)
      target = path.empty? ? @repo_root : full_path(path)
      @client.contents(REPO, path: target).map(&:name)
    rescue Octokit::NotFound
      []
    end

    # Cerca un pattern testuale in un file o in tutti i file di una directory.
    # Restituisce righe nel formato: "path:line_number: content".
    # Matching case-insensitive. Se il path è una directory, scansiona solo i file immediati.
    def grep_files(pattern, path)
      regex = Regexp.new(Regexp.escape(pattern.to_s), Regexp::IGNORECASE)
      target = full_path(path)

      node = @client.contents(REPO, path: target)
      entries = node.is_a?(Array) ? node.select { |e| e.type == "file" } : [node]

      results = entries.flat_map do |entry|
        content = get_file_content(strip_repo_root(entry.path))
        next [] unless content

        content.each_line.with_index(1).filter_map do |line, idx|
          next unless line.match?(regex)

          "#{strip_repo_root(entry.path)}:#{idx}: #{line.chomp}"
        end
      end

      results.empty? ? "ERROR: no matches for '#{pattern}' in #{path}" : results.join("\n")
    rescue Octokit::NotFound
      "ERROR: file or directory not found: #{path}"
    rescue RegexpError => e
      "ERROR: invalid pattern '#{pattern}': #{e.message}"
    end

    # Scrive tutti i file in un unico commit atomico sul branch.
    def commit_files_atomically(files, message:, branch:)
      branch_data   = @client.branch(REPO, branch)
      parent_sha    = branch_data.commit.sha
      base_tree_sha = branch_data.commit.commit.tree.sha

      tree_items = files.map do |file|
        fpath = full_path(file[:path])
        blob  = @client.create_blob(REPO, Base64.strict_encode64(file[:content]), "base64")
        Calvin::LOG.info "blob created: #{fpath} (#{blob})"
        { path: fpath, mode: "100644", type: "blob", sha: blob }
      end

      new_tree   = @client.create_tree(REPO, tree_items, base_tree: base_tree_sha)
      new_commit = @client.create_commit(REPO, message, new_tree.sha, parent_sha)
      @client.update_ref(REPO, "heads/#{branch}", new_commit.sha)

      Calvin::LOG.info "branch #{branch} aggiornato a #{new_commit.sha}"
      new_commit.sha
    end

    # Crea un branch dal default branch
    def create_branch(branch_name)
      default_branch = @client.repository(REPO).default_branch
      sha = @client.branch(REPO, default_branch).commit.sha
      @client.create_ref(REPO, "refs/heads/#{branch_name}", sha)
    rescue Octokit::UnprocessableEntity
      # branch already exists
    end

    # Apre una PR
    def create_pull_request(title:, body:, head:, base: "main")
      @client.create_pull_request(REPO, base, head, title, body)
    end

    # Ritorna i dati di una PR (branch, head sha, stato, ecc.).
    def fetch_pull_request(number)
      @client.pull_request(REPO, number)
    end

    # Ritorna i path dei file modificati in una PR,
    # con il repo_root prefix strippato (path relativi al progetto).
    def list_pull_request_files(number)
      @client.pull_request_files(REPO, number).map do |f|
        strip_repo_root(f.filename)
      end
    end

    private

    def full_path(path)
      @repo_root.empty? ? path : "#{@repo_root}/#{path}"
    end

    def strip_repo_root(path)
      return path if @repo_root.empty?

      prefix = "#{@repo_root}/"
      path.start_with?(prefix) ? path.delete_prefix(prefix) : path
    end
  end
end
