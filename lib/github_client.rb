# frozen_string_literal: true
# Wrapper Octokit. Centralizza tutte le chiamate GitHub API.
#
# repo_root: prefisso applicato a tutti i path di file (es. "backend/api").
# Viene determinato dalle label dell'issue tramite REPO_ROOTS in calvin.rb.

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

    # Crea o aggiorna un file nel repo sul branch specificato.
    # Cerca il SHA prima sul branch, poi su main — cosi' i file gia'
    # esistenti su main vengono aggiornati con diff visibili nella PR.
    # Applica repo_root al path se configurato.
    def create_or_update_file(path, content, message, branch)
      fpath = full_path(path)

      existing = begin
        @client.contents(REPO, path: fpath, ref: branch)
      rescue Octokit::NotFound
        begin
          @client.contents(REPO, path: fpath, ref: "main")
        rescue Octokit::NotFound
          nil
        end
      end

      params = { message: message, content: Base64.strict_encode64(content), branch: branch }
      params[:sha] = existing.sha if existing

      @client.create_contents(REPO, fpath, message, content, params)
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
