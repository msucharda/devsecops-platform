---
name: implement
description: "Implementuj dohodnutou změnu pomocí TDD a cílené validace; dokončení celé dodávky má jediného vlastníka."
---

# Implementace

Načti zadaný ticket nebo spec a relevantní pravidla repozitáře. Při nejasném
odkazu se zeptej; již schválený rozsah znovu nenavrhuj.

## Rozsah odpovědnosti

- **Dílčí práce:** volající vlastní celou dodávku, například `/implement-spec`.
  Implementuj zadané chování a proveď cílené ověření. Vrať změny, výsledky
  a nesplněná kritéria; závěrečné review, publikaci a handoff vlastní volající.
- **Samostatná dodávka:** aktuální session vlastní i dokončení. Po implementaci
  proveď `code-review` a dokonči dodávku podle `AGENTS.md`.

Výchozí režim je samostatná dodávka. Dílčí režim musí vyplývat ze zadání
vlastníka celku; není to výjimka z testů, bezpečnostních checkpointů ani
commit-bound gate před pushem.

## Práce

Vyvolej `tdd` na předem dohodnutých seams, kde lze chování testovat.
Pro čistou dokumentaci ověř konzistenci a odkazy; pokud existují kontraktní
testy dokumentace, použij je. Nevytvářej tautologické testy slov v textu.

Spouštěj nejmenší relevantní testy a typecheck podle změny. Povinnou závěrečnou
validaci určuje repozitář; automaticky nepřidávej lokální plnou sadu vedle CI.
Změny dělej přímo, bez dalšího implementačního agenta.

Hotovo v dílčím režimu: chování a cílené ověření jsou doložené, omezení výslovná.
Hotovo u samostatné dodávky: navíc splněné podmínky dokončení z `AGENTS.md`.
