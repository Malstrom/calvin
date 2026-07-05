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

    # Ritorna il contenuto di un file (branch default) o nil se non esiste.
    # Applica repo_root al path se configurato.
    def get_file_content(path)
      content = @client.contents(REPO, path: full_path(path))
      Base64.decode64(content.content)
    rescue Octokit::NotFound
      nil
    end

    # Ritorna il contenuto di un file SENZA applicare repo_root.
    # Usato da RunReporter per leggere .calvin/reports/ indipendentemente
    # dal repo_root configurato per il progetto corrente.
    def get_file_content_raw(path)
      content = @client.contents(REPO, path: path)
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

    private

    def full_path(path)
      @repo_root.empty? ? path : "#{@repo_root}/#{path}"
    end
  end
end
