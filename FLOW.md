# Calvin — Development Flow

Questo documento descrive l'intero flusso di sviluppo di Synca, dalla conversazione in chat fino al merge in produzione.

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

## Scenari chat disponibili

| Scenario | Trigger | Output |
|----------|---------|--------|
| `session_start` | Inizio conversazione, status progetto | Riepilogo PR aperte, issue in corso |
| `create_epic` | "crea epic", idea di feature | Issue GitHub con label `epic` |
| `decompose` | "decomponila", epica esistente | Sub-issue task collegate all'epica |
| `report_bug` | "traccia il bug", comportamento inatteso | Issue bug con descrizione strutturata |
| `refine_task` | "raffina la task", numero issue | Issue aggiornata con AC, decisioni, rischi |
| `agent_prompt` | "scrivi il prompt", task pronta | Prompt per esecuzione asincrona |
| `review_pr` | "review", numero PR | Analisi PR con osservazioni |
| `update_context` | PR mergiata, nuova decisione | Aggiornamento `.agent.yml` / `overview.yml` |
| `calvanize` | "calvanize", nuovo repo | Bootstrap Calvin su nuovo target repo |

---

## Flussi Calvin automatici

| Label | Repo | Flow | Descrizione |
|-------|------|------|-------------|
| `calvin` | synca issue | `ExploreFlow` | Implementa la feature dalla issue |
| `calvin-fix` | synca PR | `PrReviewFlow` | Fixa i test CI falliti sulla PR |
| `calvin-rubocop` | synca PR | `PrRubocopFixFlow` | _(pianificato — issue #18)_ |

---

## Branch naming

```
issue-{N}-{slug-titolo-issue}-calvin
```

Esempio: `issue-101-us-03-signals-summary-get-apiv1signalsmesummary-calvin`

---

## Tracciabilità

- Ogni run Calvin è registrata in `backend/api/.calvin/reports/runs.csv`
- Ogni PR e commento Calvin contiene:
  - Firma `Implemented by Calvin via Codestral (codestral-latest)`
  - Token usage table (prompt / completion / total)
  - Checkbox `- [ ] Approved` per tracciare l'approvazione umana
