# Vývojový postup

Uživatelský tok je `/grill-with-docs → /to-spec → /to-tickets → /lever deliver #<spec>`.
Tento dokument je jediný zdroj pravidel pro organizaci dodávky a předávání.
[`AGENTS.md`](../../AGENTS.md) směruje na ostatní závazná pravidla;
modely určuje [model routing](model-routing.md).

## Návrh

Uživatel ve stejné session spustí `/grill-with-docs`, potom `/to-spec`
a `/to-tickets`. Interview zaznamenává rozhodnutí do doménové dokumentace;
spec a tickets jsou v issue trackeru. Předání do implementace vyžaduje
schválenou spec, schválený graf tickets a přijatý návrhový PR, pokud návrh
měnil verzovanou dokumentaci. Samotné zveřejnění issue neznamená schválení.

### Kontrakt předání

Spec obsahuje původní zadání, akceptační kritéria a odkazy na přijatá rozhodnutí.
Před zveřejněním spec, ticketu nebo jiného podkladu odstraň přihlašovací údaje,
osobní a důvěrné informace i skutečná data instance podle
[ADR 0012](../adr/0012-public-source-repository.md). Každé odstranění označ
zástupnou hodnotou `[REDACTED: kategorie]`; bezpečný zbytek původního zadání
zachovej doslova. Pravidlo platí i pro přílohy a převzaté důkazy. Pokud po redakci
nelze požadavek jednoznačně specifikovat, publikaci zablokuj a vyžádej si
bezpečné upřesnění místo zveřejnění původních hodnot.

Každý ticket odkazuje na konkrétní kritéria spec a uvádí skutečné blokující
závislosti. Parent spec eviduje všechny tickets; souhrn pokrytí musí ukázat,
že žádné kritérium nechybí. Otevřená rozhodnutí blokující implementaci musí
být vyřešená před předáním.

Koordinátor dostane odkaz na spec, její tickets a přijaté ADR. Použije tyto
zdroje místo kopie celé konverzace, nového briefu nebo dalšího kickoff dokumentu.
Při změně spec ověří dopad na rozpracované tickets a vrátí nové rozhodnutí
uživateli; sám scope nerozšíří.

## Společná pravidla implementace

Mimo explicitní lever delivery pracuje aktuální session přímo a vlastní
implementaci, integraci, review, validaci i předání svého výsledku.
Samotný ticket ani vyvolání `implement` nezakládá koordinační session.

Paralelní implementace vyžaduje výslovný souhlas uživatele; explicitní
`/lever deliver` je tímto souhlasem pro schválenou dodávku. V obou režimech
smějí běžet nejvýš dva implementátoři v celé dodávce. Delegovaný implementátor
další implementátory nespouští. Nezávislé review a security checkpoint tento
limit nespotřebovávají.

## Implementace přes lever

Uživatel zahájí nebo obnoví dodávku explicitním `/lever deliver #<spec>`.
Příkaz nevyvolává návrhová session automaticky. Lever je závislost z instalovaného
pluginu; repo jeho kopii ani stejnojmenný router neobsahuje. Pokud příkaz není
dostupný, agent nahlásí blokaci a požadavek na zpřístupnění pluginu. Samotná
zmínka o leveru ani dokončení `/to-tickets` dodávku nespouští.

### Organizace a rozsah

- Aktuální session koordinuje dodávku a vlastní pokrytí celé spec, graf závislostí,
  integraci a závěrečný audit. Implementaci deleguje vlastníkům jednotlivých větví práce.
- Koordinátor volí počet implementátorů podle nezávislosti práce v mezích
  společných pravidel implementace; paralelismus není povinný.
- Ticket určuje výsledek, ne session ani PR. Koordinátor seskupí provázané tickets
  k jednomu implementátorovi. Nezávisle přijatelná větev práce má vlastní branch a PR;
  samostatný ticket je dostatečný důvod pro nový PR jen tehdy, když lze jeho výsledek
  přijmout nezávisle. Sdílené soubory, kontrakty a fixtures patří do grafu závislostí.
- Implementátor vlastní změny, cílené ověření, review, opravy a publikaci své větve
  pomocí `implement` v samostatném režimu. Přiřazení zahrnuje odkazy na zdroje, rozsah,
  podmínku dokončení a podíl rozpočtu. Běžné opravy nevyžadují nového vlastníka.
- Uvnitř jedné větve může ověřená implementace odblokovat navazující ticket před merge.
  Mezi větvemi se závislost uvolní až po přijetí předpokladu do cílové větve;
  jiný postup včetně stacku vyžaduje výslovný souhlas. Externí závislost musí být
  skutečně splněná. Lokální implementace sama issue neuzavírá.

### Nastavení a stav

Koordinátor převezme existující spec jako parent issue a existující tickets jako
podúlohy podle [pravidel trackeru](issue-tracker.md). Doplní pouze provozní metadata
leveru: vlastníka, marker koordinátora, stav, důkazy a blokace. Zachová zadání,
schválená kritéria, rozhodnutí i původní issue čísla; nevytváří druhý brief ani
duplicitní tickets. Při cizím aktivním vlastníkovi zůstane read-only do předání.

Před delegováním vyřeší spend, konečný rozpočet běhu a merge mandát podle nastavení
leveru, omezení repozitáře a platformy. Chybějící rozpočet nebo mandát si nesmí
domyslet. Osobní spend není počet povinných větví práce a nezvyšuje zdejší limit.
Samotný `deliver` není nový merge ani release mandát.

Výchozí běh je konečný: jen schválené tickets, bez doplňování backlogu, pravidelných
sweepů, automatických restartů po STOP nebo změn osobních či pluginových instrukcí.
Po splnění spec skončí. Dlouhodobý běh, automation, nový scope a release vyžadují
samostatné zadání. Čekání, resume a STOP se řídí `AGENTS.md`, nikoli výchozím
refill nebo takeover režimem pluginu.

### Dokončení

Vlastník každého PR provede `code-review` své integrované změny podle
[pravidel review](repository-rules.md#code-review). Koordinátor převezme důkazy
na přesném head SHA, ověří pokrytí spec a vazby mezi větvemi. Stejné review
nezadává znovu jen kvůli předání; změněný sdílený kontrakt nebo nový integrační
rozdíl vyžaduje review dotčeného celku.

[Lokální CI](local-ci.md) a [merge gate](repository-rules.md#merge-gate) platí pro
každý PR. Koordinátor ověří gate znovu před merge; tvrzení implementátora ho
nenahrazuje. Stav parent issue může být `hotovo` až po splnění všech kritérií
a předepsaných podmínek předání. Nezamergovaný nebo blokovaný PR není dokončená
dodávka. Uzavření issues se řídí trackerem.

Retrospektiva ani samostatný retrospektivní agent nejsou součástí dokončení.
Dřívější rozhodnutí zrušil [PR #248](https://github.com/msucharda/devsecops-platform/pull/248).
Poznatky se ukládají průběžně do Copilot Memory podle `AGENTS.md`.
Dreaming není součástí tohoto workflow.

## Umístění a migrace skills

Autoritativní verze workflow je v `.github/skills`. Toto umístění podporuje
[Copilot app a CLI](https://docs.github.com/en/copilot/concepts/customizations/agent-skills).
Tři návrhové uživatelské příkazy zachovávají `disable-model-invocation: true`;
podpůrné skills zůstávají vyvolatelné agentem. `/implement-spec` byl nahrazen
explicitním `/lever deliver`; jeho skill a metadata se z discovery odstraňují.

Historicky převzaté osobní skills: `grill-with-docs`, `to-spec`, `to-tickets`,
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
