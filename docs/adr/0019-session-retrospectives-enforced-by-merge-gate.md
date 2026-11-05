# Retrospektivy implementačních session vynucuje merge gate

Každá implementační session v tomto repozitáři musí před handoffem commitnout retrospektivu do `docs/agents/retros/`. Merge gate bez ní PR zamítne. Denní destilace převádí opakované nálezy na pravidla v `docs/agents/guide/`. Rozhodnutí schválil uživatel 5. 11. 2026. Důvod: agenti opakovaně hledají stejná fakta a opakují stejné chyby, protože poznatek z jedné session se do další nepřenese.

Mechanismus platí jen pro tento repozitář.

## Průběh

1. Implementační session běží jako custom agent `implementer` (`.github/agents/implementer.agent.md`). Agenta nastavuje skill `issue-kickoff`. `AGENTS.md` ho vyžaduje i pro session spuštěnou bez kickoffu.
2. Po zelené CI a vyřešeném Copilot review spustí `implementer` subagenta `session-retro` s čerstvým kontextem. Subagent čte záznam session ze session store: konverzaci, neúspěšná a opakovaná volání nástrojů a opravy od uživatele. Zapíše `docs/agents/retros/<YYYY-MM-DD>-<session-id>.md`. Commit retrospektivy je poslední commit před handoffem.
3. Kontrola G12 merge gate vrátí `retro-missing`, pokud PR nepřidá retrospektivu, jejíž frontmatter `pr` se rovná číslu PR.
4. Denní automation spustí destilaci, pokud existují alespoň 3 nezpracované retrospektivy. Destilační agent otevře PR, které:
   - zapíše pravidla do `docs/agents/guide/<téma>.md`,
   - zapíše osamocené nálezy do `docs/agents/retros/candidates.md`,
   - smaže zpracované retrospektivy.

## Pravidla obsahu

- Retrospektiva obsahuje jen parafrázované nálezy s odkazy na soubory, příkazy a commity. Nesmí obsahovat doslovné citace konverzace, data instance ([ADR 0012](0012-public-source-repository.md)) ani osobní údaje.
- Nález se stane pravidlem po výskytu ve 2 nezávislých session. Bezpečnostní nález nebo nález s vysokou cenou se může stát pravidlem po jednom výskytu.
- Pokud nález odporuje `AGENTS.md`, ADR nebo existujícímu průvodci, destilační agent ho zapíše do sekce `## Otevřené otázky` v PR. Existující pravidlo nesmí tiše změnit.
- O přesunu pravidla z průvodce do `AGENTS.md` rozhoduje uživatel.

## Výjimka z retrospektivy

- Tělo PR může obsahovat marker `<!-- retro: none <důvod> -->`. Povolené důvody jsou `bootstrap`, `human` a `distillation`. PR od Dependabotu G12 pozná podle autora.
- Platný marker vrátí `pass` s varováním `retro-waived`. `Invoke-GatedMerge.ps1` u výjimky vyžaduje parametr `-AcknowledgeRetroWaiver <head SHA>`.
- Důvod: agenti běží pod účtem uživatele, takže G12 nerozliší marker od agenta a od uživatele. Výjimku proto potvrdí koordinátor se souhlasem uživatele při merge, nikoli autor PR.

## Zvažované varianty

- Úložiště mimo repozitář: zamítnuto. Cloud session a další vývojáři by k záznamům neměli přístup. Důsledek: retrospektivy jsou veřejné.
- Hook `sessionEnd`: zamítnuto. Hook spouští jen shell příkaz a běží po konci session, kdy už nejde commitnout do PR.
- Sebereflexe implementačního agenta: zamítnuto. Review ve stejném modelu a kontextu v experimentu #13 nenašlo chybu, kterou nezávislé review našlo.
- Pravidla přímo v `AGENTS.md`: zamítnuto. `AGENTS.md` se načítá v každé session. Tematický soubor průvodce agent čte jen při potřebě.
- Jen instrukce agenta bez gate: zamítnuto. Agent může měkké pravidlo vynechat.

## Důsledky

- Commit retrospektivy nespustí další kolo Copilot review, protože ruleset `main: Copilot review gate` má `review_on_push: false`. Merge gate vydá jen varování `copilot-review-stale`.
- Destilační automation zatím běží app-local na stroji uživatele. Přesun do cloud automation je plánovaný.
- PR, která tento mechanismus zavádějí, a PR rozpracovaná před zapnutím G12 používají marker `<!-- retro: none bootstrap -->`.
