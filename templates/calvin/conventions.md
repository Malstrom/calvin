# Convenzioni del progetto

<!--
  Copiare in `.calvin/conventions.md` alla radice del repo target e riscrivere per il progetto.

  Questo file viene iniettato INTEGRALMENTE nel system prompt di Calvin, a ogni run, prima
  di qualunque contesto recuperato dal DB vettoriale. È il posto dove vivono le regole
  SEMPRE valide di questo progetto.

  Tre criteri per decidere se una regola va qui:

  1. Se è verificabile a macchina → non va qui, va in `forbidden_patterns` dentro
     project.yml, o in un gate del Validator. Una regola controllabile non va chiesta
     per favore a un modello.
  2. Se vale sempre, in ogni task → va qui.
  3. Se vale solo in un contesto specifico e sono decine → non va qui, la trova il
     retrieval. Questo file ha un budget di 8 KB: oltre viene troncato.

  Scrivere regole positive ("fai X"), non divieti vaghi. Ogni regola con un esempio breve
  quando l'esempio chiarisce più della prosa.
-->

## Architettura

- I controller restano sottili: autenticazione, chiamata al service, render. Nessuna logica
  di business e nessun hash JSON costruito a mano.
- La logica di business sta nei service object, uno per caso d'uso.
- I job orchestrano e delegano al service. Ogni job è idempotente: eseguirlo due volte non
  lascia stato incoerente.

## Dati

- Ogni cambiamento allo schema passa da una migration nuova, mai da una modifica a una
  migration già mergiata.

## Configurazione

- Nessuna costante di business inline nel codice (timeout, TTL, limiti, host). Vanno nella
  configurazione del progetto e si leggono da lì.

## Testo per l'utente

- Ogni stringa che un utente può leggere passa da I18n. Nessun testo inline in Ruby o ERB.
