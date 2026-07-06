# Calvin

Agente di sviluppo autonomo per Synca. Igor crea le issue in chat con Perplexity, aggiunge una label, e Calvin esegue — apre PR, fixa i test, aggiorna il contesto.

---

## Flusso completo

```mermaid
flowchart TD
    subgraph CHAT ["💬 Chat con Igor (Perplexity Space)"]
        A(["Igor ha un'idea o un obiettivo"]) --> B["Ragionamento in chat\nsu epiche, architettura, scope"]
        B --> C["scenario: create_epic\n→ Issue GitHub con label epic"]
        C --> D["scenario: decompose\n→ Sub-issue task per l'epica"]
        D --> E["scenario: refine_task\n→ Descrizione dettagliata\ncon AC, decisioni, rischi"]
        E --> F{"Task pronta?"}
        F -- No --> E
        F -- Sì --> G["Igor aggiunge label\n\"calvin\" sulla issue"]
    end

    subgraph EXPLORE ["🤖 Calvin — ExploreFlow (GitHub Actions)"]
        G --> H["ModeRouter → :explore_issue"]
        H --> I["ContextBuilder\nbuilds prompt dalla issue"]
        I --> J["ReActLoop — PHASE 1\nexplore_system.md\nread_file / list_dir / done"]
        J --> K{"Abbastanza contesto?"}
        K -- No, altro giro --> J
        K -- Sì, done() --> L["ReActLoop — PHASE 2\nimplement_system.md\nsingola call → FILE: blocks + PR_BODY"]
        L --> M["FileParser\nparsa FILE: blocks"]
        M --> N["CommitAndPr\nbranch: issue-NNN-titolo-calvin\nPR body firmata + checkbox Approved"]
        N --> O["PostSteps\nRubocopAutocorrect + RunReporter"]
    end

    subgraph CI ["⚙️ CI Synca (GitHub Actions)"]
        O --> P["CI runs: tests, Brakeman, bundler-audit"]
        P --> Q{"CI passa?"}
        Q -- Sì --> R["Commento bot ci-report\n✅ all green"]
        Q -- No --> S["Commento bot ci-report\n❌ errori + backtrace"]
    end

    subgraph REVIEW ["🔁 Calvin — PrReviewFlow"]
        S --> T["Igor aggiunge label\n\"calvin-fix\" sulla PR"]
        T --> U["ModeRouter → :pr_review"]
        U --> V["BacktraceExtractor\nfile in scope nel perimetro PR"]
        V --> W["fetch_snippet\n±20 righe attorno alla riga del backtrace"]
        W --> X["Singola call LLM\npr_review_system.md"]
        X --> Y["FileParser + commit sul branch PR\ncommento review firmato + token usage"]
        Y --> P
    end

    subgraph MERGE ["✅ Review umana e merge"]
        R --> Z["Igor revisiona la PR"]
        Z --> AA{"Approvato?"}
        AA -- No --> BB["scenario: review_pr\ncommento con osservazioni"]
        BB --> CC["Igor o Calvin correggono manualmente"]
        CC --> P
        AA -- Sì --> DD["Igor spunta checkbox Approved\nnella PR"]
        DD --> EE["Igor fa merge"]
        EE --> FF["scenario: update_context\naggiorna .agent.yml / overview.yml"]
    end
```

---

## Attori

| Attore | Ruolo |
|--------|-------|
| Igor | Crea issue, aggiunge label, revisiona e mergia le PR |
| Perplexity (chat) | Ragiona su epiche e task, gestisce gli scenari, aggiorna il contesto |
| Calvin (GitHub Actions) | Esegue i flow automatici: ExploreFlow, PrReviewFlow |
| Codestral (`codestral-latest`) | Modello LLM per tutte le call |

---

## Flussi automatici

| Label | Dove | Flow | Cosa fa |
|-------|------|------|---------|
| `calvin` | issue synca | `ExploreFlow` | Implementa la feature, apre PR |
| `calvin-fix` | PR synca | `PrReviewFlow` | Fixa i test CI falliti |
| `calvin-rubocop` | PR synca | `PrRubocopFixFlow` | _(pianificato — issue #18)_ |

---

## Scenari chat

| Scenario | Trigger | Output |
|----------|---------|--------|
| `session_start` | Inizio conversazione, status progetto | Riepilogo PR aperte, issue in corso |
| `create_epic` | "crea epic" | Issue con label `epic` |
| `decompose` | "decomponila" | Sub-issue task collegate all'epica |
| `report_bug` | "traccia il bug" | Issue bug strutturata |
| `refine_task` | "raffina la task" | Issue aggiornata con AC, decisioni, rischi |
| `agent_prompt` | "scrivi il prompt" | Prompt per esecuzione asincrona |
| `review_pr` | "review", numero PR | Analisi PR con osservazioni |
| `update_context` | PR mergiata | Aggiornamento `.agent.yml` / `overview.yml` |
| `calvanize` | "calvanize" | Bootstrap Calvin su nuovo repo |

---

## Branch naming

```
issue-{N}-{slug-titolo-issue}-calvin
```

Esempio: `issue-101-us-03-signals-summary-get-apiv1signalsmesummary-calvin`

---

## Tracciabilità

- Ogni run è registrata in `backend/api/.calvin/reports/runs.csv`
- Ogni PR e commento Calvin contiene:
  - Firma `Implemented by Calvin via Codestral (codestral-latest)`
  - Token usage table (prompt / completion / total)
  - Checkbox `- [ ] Approved` per tracciare l'approvazione umana

---

## Struttura repo

```
bin/calvin.rb           ← entry point
lib/
  boot.rb               requires, config, logging
  mode_router.rb        label → mode symbol
  explore_flow.rb       ExploreFlow orchestrator
  pr_review_flow.rb     PrReviewFlow orchestrator
  react_loop.rb         ReActLoop multi-turn
  context_builder.rb    builds prompt da issue
  file_parser.rb        parsa FILE: blocks
  commit_and_pr.rb      commit + apre PR
  mistral_client.rb     HTTP client Mistral API
  github_client.rb      GitHub API wrapper
  rubocop_autocorrect.rb  autocorrect + commit
  rubocop_runner.rb     rubocop core
  run_reporter.rb       aggiorna runs.csv
  pr_body_builder.rb    firma PR body + commenti
  flow_result.rb        contratto condiviso tra flow
  post_steps.rb         RunReporter + RubocopAutocorrect
config/
  calvin.yml            tutte le costanti runtime
  prompts/rails/
    explore_system.md   system prompt PHASE 1
    implement_system.md system prompt PHASE 2
    pr_review_system.md system prompt PrReviewFlow
```

---

## Requirements

- Ruby, gem `octokit`, `faraday`, `dry-monads`
- Secrets: `GITHUB_TOKEN`, `MISTRAL_API_KEY`
- Label `calvin` e `calvin-fix` create nel repo target
