# Vývojový postup

Výchozí postup má jednu návrhovou session a jednu implementační session.
Každá pracuje přímo. Ticket popisuje ověřitelný výsledek, ne počet agentů.
Závazná pravidla delegování, paměti, validace a merge jsou v
[`AGENTS.md`](../../AGENTS.md); modely v [model routingu](model-routing.md).

## Návrh

Uživatel ve stejné session spustí `/grill-with-docs`, potom `/to-spec`
a `/to-tickets`. Interview zaznamenává rozhodnutí do doménové dokumentace;
spec a tickets jsou v issue trackeru. Návrhový PR přijme dokumentaci před
zahájením implementace. Nová implementační session dostane odkazy na spec,
tickets a přijaté ADR, ne kopii celé konverzace nebo další kickoff dokument.

## Implementace a dokončení

Uživatel spustí `/implement-spec` v nové session nad přijatým návrhem.
Session implementuje připravené tickets sekvenčně na přidělené větvi pomocí
`implement` v dílčím režimu. Interní závislosti odblokuje ověřená implementace;
externí závislosti musí být skutečně splněné.

Vlastník celku ověří pokrytí spec a provede závěrečné `code-review`.
Opravy zpracuje sám. Repo gate před pushem a Linux CI na finálním SHA
zůstávají povinné. Publikace má jeden PR; tento postup nezavádí stack.
Merge vyžaduje samostatný mandát a předepsaný merge gate.

Retrospektiva ani samostatný retrospektivní agent nejsou součástí dokončení.
Dřívější rozhodnutí zrušil [PR #248](https://github.com/msucharda/devsecops-platform/pull/248).
Poznatky se ukládají průběžně do Copilot Memory podle `AGENTS.md`.
Dreaming není součástí tohoto workflow.

## Umístění a migrace skills

Autoritativní verze workflow je v `.github/skills`. Toto umístění podporuje
[Copilot app a CLI](https://docs.github.com/en/copilot/concepts/customizations/agent-skills).
Čtyři uživatelské příkazy zachovávají `disable-model-invocation: true`;
podpůrné skills zůstávají vyvolatelné agentem.

Převzaté osobní skills: `grill-with-docs`, `to-spec`, `to-tickets`,
`implement-spec`, `implement`, `code-review`, `grilling`, `domain-modeling`,
`tdd`, `codebase-design` a `security-checkpoint`. Zdrojové balíčky byly lokální
soubory uživatele; revize jejich původní instalace není doložená. Související
šablony a metadata zůstávají součástí balíčků. Jazykový skill `controlled-czech`
je nadále osobní závislostí popsanou v `AGENTS.md`; tato migrace ho nemění.

### Upstream původ a licence

Deset balíčků vychází z repozitáře
[`mattpocock/skills`](https://github.com/mattpocock/skills/tree/4ae2317ddb22b046e26455e4f9c9b3aaaf62212d).
Původ byl ověřen porovnáním migračních záloh s revizí
`4ae2317ddb22b046e26455e4f9c9b3aaaf62212d`; jde o srovnávací revizi,
nikoli tvrzení o revizi původní instalace.

| Zdejší balíčky | Upstream cesta v uvedené revizi |
|---|---|
| `grill-with-docs`, `to-spec`, `to-tickets`, `implement-spec`, `implement`, `code-review`, `domain-modeling`, `tdd`, `codebase-design` | [`skills/engineering/<název>`](https://github.com/mattpocock/skills/tree/4ae2317ddb22b046e26455e4f9c9b3aaaf62212d/skills/engineering) |
| `grilling` | [`skills/productivity/grilling`](https://github.com/mattpocock/skills/tree/4ae2317ddb22b046e26455e4f9c9b3aaaf62212d/skills/productivity/grilling) |

Instrukce jsou upravené pro zdejší workflow. Převzaté části a podpůrné soubory
zachovávají copyright `Copyright (c) 2026 Matt Pocock` a úplné znění
[MIT licence](../../.github/skills/LICENSE.mattpocock), převzaté z
[upstream licence](https://github.com/mattpocock/skills/blob/4ae2317ddb22b046e26455e4f9c9b3aaaf62212d/LICENSE).
Například `tdd/mocking.md` odpovídá upstream blobu
`71cbfee674d93244ce81d1830b930ca9a69200bd` po normalizaci konců řádků.
`security-checkpoint` pochází z lokálního skillu uživatele a tomuto upstreamu
se nepřisuzuje. Při dalším kopírování převzatých částí přilož také jejich licenci.

### Postup migrace

Při přechodu nejdřív zachovej přesnou zálohu osobních balíčků mimo adresáře,
ve kterých runtime hledá skills. Ověř repo kopie a jejich relativní odkazy,
commitni je a až potom odstraň z discovery původní přesunuté balíčky.
`issue-kickoff` a jeho šablona se vyřazují, nikoli přesouvají do workflow.
Nevytvářej globální symlink do dočasného worktree.

Globální model routing musí pro tento repozitář odkazovat na
`docs/agents/model-routing.md`; případná pravidla pro ostatní projekty
zůstávají oddělená. Osobní soubory nejsou součástí PR a lokální migrační
zásahy musí být v handoffu uvedené zvlášť. Po přesunu nejsou původní osobní
skills automaticky dostupné v jiných repozitářích. Obnova používá zálohu;
současné aktivní kopie s odlišným chováním nejsou podporovaný stav.

## Vyhodnocení nákladů

Při porovnání workflow sleduj návrh a implementaci odděleně: dostupnou
účtovanou spotřebu včetně potomků, čas do přijatelného PR, počet agentů
a opravných kol. Není-li účtovaná spotřeba dostupná, uveď to; počet tokenů
nevydávej za cenu. Tento postup nespouští další benchmark ani monitoring.
