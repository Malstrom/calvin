# Attaccare Calvin a un progetto Rails

Calvin non sa niente del tuo progetto finché non glielo dici. Tutto ciò che è specifico di
un'applicazione — dove sta il codice, come si lanciano i test, quali convenzioni seguire — vive
in `.calvin/` **dentro il repo target**, non dentro Calvin.

Collegare un nuovo progetto significa creare due file in quel repo. Calvin non va modificato.

```
il-tuo-repo/
├── .calvin/
│   ├── project.yml       com'è fatto il progetto   → letto dal motore
│   └── conventions.md    le sue regole             → iniettato nel prompt del modello
└── app/ …
```

Se `.calvin/` non esiste, Calvin assume un'applicazione Rails standard: app in root, Minitest,
comandi `bin/rails` di serie. Per molti progetti è già corretto.

---

## 1. `.calvin/project.yml`

Il profilo tecnico. Nessuna chiave è obbligatoria: quelle assenti prendono il default generico.
Il file di riferimento commentato è in [`templates/calvin/project.yml`](../templates/calvin/project.yml).

### Rails standard, app in root

Il caso più comune non richiede quasi niente:

```yaml
app_root: ""
test:
  framework: minitest
  command: bin/rails test
```

### Monorepo, app in una sottocartella

```yaml
app_root: backend/api

test:
  framework: minitest
  command: bin/rails test

gates:
  zeitwerk: bin/rails zeitwerk:check
  migrate:  bin/rails db:migrate

forbidden_patterns:
  - paths: "app/models/**"
    pattern: '^\s*validates?\s'
    message: "i model del progetto sono strutture dati: la validazione sta nei contract"
```

`app_root` è la chiave che conta di più: **tutti** i path che Calvin legge, scrive e mette nelle
PR sono relativi a quella cartella. Con `app_root: backend/api`, il modello ragiona su
`app/models/user.rb` e Calvin scrive su `backend/api/app/models/user.rb`.

### Progetto a RSpec

```yaml
test:
  framework: rspec
  command: bundle exec rspec
  path_map:
    - from: 'app/(.*)\.rb'
      to:   'spec/\1_spec.rb'
```

### Progetto senza alcuni gate

Un gate con comando vuoto viene **saltato**, non fatto fallire:

```yaml
gates:
  zeitwerk: ""            # nessun autoloading Zeitwerk da controllare
  migrate: bin/rails db:migrate
```

---

## 2. `.calvin/conventions.md`

Le regole sempre valide del progetto, iniettate integralmente nel system prompt a ogni run.
Esempio di partenza in [`templates/calvin/conventions.md`](../templates/calvin/conventions.md).

Prima di scrivere una regola qui, chiediti dove va davvero:

| Se la regola… | va in | perché |
|---|---|---|
| è verificabile a macchina | `forbidden_patterns` o un gate del `Validator` | un controllo deterministico non dipende dall'attenzione del modello |
| vale sempre, in ogni task | `conventions.md` | viene iniettata a ogni run, senza passare da una ricerca |
| vale solo in contesti specifici, e sono decine | DB vettoriale | non entrerebbero mai tutte in un prompt |
| riguarda come si comporta un agente | prompt fissi di Calvin | non è del progetto |

Il budget è 8 KB (`conventions.max_bytes` in `config/calvin.yml`): oltre, il file viene troncato
con un warning. È un limite voluto — se servono più di 8 KB di regole sempre attive, quasi
sempre significa che alcune sono contestuali e vanno nel DB vettoriale.

---

## 3. Il workflow nel repo target

Calvin si esegue via `workflow_call`. Nel repo target:

```yaml
# .github/workflows/calvin.yml
name: Calvin
on:
  issues:
    types: [labeled]

jobs:
  calvin:
    if: github.event.label.name == 'calvin'
    uses: Malstrom/calvin/.github/workflows/calvin-engine.yml@main
    with:
      issue_number: ${{ github.event.issue.number }}
      target_repo:  ${{ github.repository }}
      validation_level: static        # static | full
    secrets:
      GH_TOKEN:        ${{ secrets.GH_TOKEN }}
      MISTRAL_API_KEY: ${{ secrets.MISTRAL_API_KEY }}
```

Il workflow legge `app_root` da `.calvin/project.yml` da solo: non va passato come input.

Input opzionali, tutti con default generici: `calvin_repo`, `database_url`, `git_user_name`,
`git_user_email`, `dry_run`.

### Livelli di validazione

| Livello | Gate eseguiti | Richiede |
|---|---|---|
| `static` (default) | `ruby -c`, rubocop, gate strutturali | niente — job veloce |
| `full` | + `zeitwerk:check`, `db:migrate`, test mirati | Postgres nel job e `bundle install` del target |

I gate strutturali girano sempre: diff-guard anti-troncamento, allineamento fra piano e output,
timestamp della migration, route senza controller, `forbidden_patterns` del progetto.

---

## 4. Prerequisiti nel repo target

- Le label `calvin` e `calvin:red`
- I secret `GH_TOKEN` e `MISTRAL_API_KEY`
- Per `validation_level: full`: un servizio Postgres nel job e le dipendenze installabili

---

## Cosa succede se non configuri niente

Calvin parte lo stesso, con i default generici Rails. Perdi tre cose:

1. **`app_root`** — se l'app non è in root, Calvin cerca i file nel posto sbagliato.
   *È l'unico caso in cui il file è davvero obbligatorio.*
2. **Le convenzioni** — il modello segue i pattern che trova leggendo il codice, senza una
   guida esplicita. Funziona, ma è meno prevedibile.
3. **I `forbidden_patterns`** — nessun controllo deterministico sulle regole del progetto.

### Fallback legacy

Se `.calvin/project.yml` manca, Calvin cerca `app_root` nella mappa `repo.roots` di
`config/calvin.yml`, associata alle label della issue. È una rete per i repo collegati prima
dell'introduzione del profilo, e verrà rimossa: quando compare il warning
`ProjectProfile: .calvin/project.yml assente`, crea il file.
