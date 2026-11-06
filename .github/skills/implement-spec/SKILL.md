---
name: implement-spec
description: "Implementuj schválenou spec a její tickets přímo v aktuální session na jedné větvi."
disable-model-invocation: true
---

# Přímá implementace spec

Aktuální session vlastní celou dodávku. Použij přidělený worktree a větev;
nevytvářej koordinační session, další větev ani samostatného implementera
pro každý ticket. Postup a odpovědnosti určuje
[vývojový postup](../../../docs/agents/development.md).

## Postup

1. Načti spec, tickets a jejich závislosti, `AGENTS.md` a relevantní ADR.
   Ověř, že větev obsahuje přijatý návrh. Pokud návrhový PR ještě není přijatý,
   oznam blokaci; nezačínej nevyžádaný stack.
2. Urči graf práce a způsob ověření kritérií. Využij schválená rozhodnutí
   a seams; neprováděj nové návrhové kolo bez konkrétního rozporu.
3. Vyber neblokovaný ticket a vyvolej `implement` v režimu **dílčí práce**.
   Změnu prováděj přímo. Po cíleném ověření zaznamenej splněná kritéria
   a pokračuj dalším ticketem.
4. Rozlišuj implementační závislost uvnitř této dodávky a externí blokaci.
   Interní ticket může odblokovat další po implementaci a ověření na stejné
   větvi; issue tím ještě není uzavřené. Externí závislost musí být skutečně
   splněná. Stav „implementováno lokálně“ nevydávej za přijatou dodávku.
5. Zkontroluj pokrytí celé spec. Proveď jedno závěrečné `code-review` celku.
   Nálezy oprav sám a ověř opravy i jejich dopady podle tohoto skillu.
6. Dokonči dodávku podle `AGENTS.md`: commit, lokální gate a při zadané
   publikaci push a jeden PR. Pravidla trackeru určují uzavření issue.
   PR vytvoř při výslovném zadání nebo pokud je standardním způsobem
   odevzdání v trackeru. Merge vyžaduje samostatný mandát.

## Delegování a blokace

Výchozí implementace je sekvenční. Paralelní implementaci lze použít jen
po výslovném souhlasu uživatele a v mezích `AGENTS.md`. Běžnou integraci
a opravy vlastní tato session; merger ani opravný implementer není další
automatický krok. Povinné nezávislé review a bezpečnostní checkpoint zůstávají.

Při blokaci použij stav `blocked` a podmínku obnovení podle `AGENTS.md`.
Nevytvářej modelovou smyčku čekání. Pokyn STOP vyžaduje nové výslovné povolení.

Hotovo: akceptační kritéria jsou doložená a splněné podmínky dokončení
z `AGENTS.md`. Založený PR ani částečná lokální validace samy o sobě nestačí.
