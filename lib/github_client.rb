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

    # Ritorna il contenuto di un file dal repo (branch default) o nil se non esiste.
    # Applica repo_root al path se configurato.
    def get_file_content(path)
      content = @client.contents(REPO, path: full_path(path))
      Base64.decode64(content.content)
    rescue Octokit::NotFound
      nil
    end

    # Scrive tutti i file in un unico commit atomico sul branch.
    #
    # files: array di { path:, content: } — path relativi a repo_root
    # message: messaggio del commit
    # branch: branch di destinazione (deve esistere già)
    #
    # Usa la Git Trees API di basso livello:
    #   1. Crea un blob per ogni file (contenuto in base64)
    #   2. Crea un tree che li raccoglie tutti, basato sul tree del branch
    #   3. Crea un commit che punta al nuovo tree
    #   4. Sposta il branch sul nuovo commit
    #
    # Risultato: N file = 1 commit invece di N commit separati.
    # Chiamate API: N blob + 1 tree + 1 commit + 1 ref update = N+3
    # (vs N*2 get + N create_contents = N*3 con il metodo precedente)
    def commit_files_atomically(files, message:, branch:)
      owner, repo_name = REPO.split("/")

      # SHA corrente del branch (serve come parent del nuovo commit)
      branch_data  = @client.branch(REPO, branch)
      parent_sha   = branch_data.commit.sha
      base_tree_sha = branch_data.commit.commit.tree.sha

      # Crea un blob per ogni file
      tree_items = files.map do |file|
        fpath = full_path(file[:path])
        blob  = @client.create_blob(REPO, Base64.strict_encode64(file[:content]), "base64")
        Calvin::LOG.info "blob created: #{fpath} (#{blob})"
        {
          path: fpath,
          mode: "100644",  # file normale
          type: "blob",
          sha:  blob
        }
      end

      # Crea il tree con tutti i blob
      new_tree = @client.create_tree(REPO, tree_items, base_tree: base_tree_sha)
      Calvin::LOG.info "tree created: #{new_tree.sha} (#{tree_items.size} file)"

      # Crea il commit
      new_commit = @client.create_commit(
        REPO,
        message,
        new_tree.sha,
        parent_sha
      )
      Calvin::LOG.info "commit created: #{new_commit.sha}"

      # Sposta il branch sul nuovo commit
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

    # Prefissa il path con repo_root se presente
    def full_path(path)
      @repo_root.empty? ? path : "#{@repo_root}/#{path}"
    end
  end
end
