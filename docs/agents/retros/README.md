# Formát retrospektivy session

Tento dokument určuje formát pro agenta `session-retro`, kontrolu G12 (#227) a destilaci (#228). Postup schválil uživatel v [ADR 0019](../../adr/0019-session-retrospectives-enforced-by-merge-gate.md). Retrospektiva zaznamenává doložené nálezy z jedné implementační session. Navržená pravidla nejsou schválená rozhodnutí.

## Soubor a frontmatter

Agent musí zapsat jeden UTF-8 soubor `docs/agents/retros/<YYYY-MM-DD>-<session-id>.md`. Datum označuje den vytvoření retrospektivy. `session-id` musí odpovídat poli `session`; UUID se zapisuje malými písmeny. Soubor `README.md` ani `candidates.md` není retrospektiva.

Soubor musí začínat YAML frontmatter ohraničeným samostatnými řádky `---`. Každý z následujících klíčů musí obsahovat právě jednu skalární hodnotu:

| Klíč | Typ a význam |
|---|---|
| `session` | Neprázdný řetězec: ID cílové session z předání úkolu. ID nesmí obsahovat oddělovač cesty. |
| `issue` | Kladné celé číslo: implementovaný GitHub issue, bez `#`. |
| `pr` | Kladné celé číslo: PR obsahující retrospektivu, bez `#`. G12 ho porovnává s číslem posuzovaného PR. |
| `date` | Řetězec v uvozovkách ve formátu `YYYY-MM-DD`; musí odpovídat datu v názvu souboru. |
| `model` | Neprázdný řetězec: model, který retrospektivu vytvořil, nikoli model implementátora. |

Agent nesmí použít duplicitní klíče ani klíče lišící se pouze velikostí písmen, kolekce, YAML tags, anchors ani aliases. Následující hodnoty jsou syntetický příklad:

```yaml
---
session: "00000000-0000-4000-8000-000000000001"
issue: 226
pr: 123
date: "2026-11-06"
model: "claude-opus-5.5"
---
```

**Výjimka pro první bootstrap ukázku #226:** pokud integrační PR ještě neexistuje, soubor může dočasně obsahovat `pr: null`. Koordinátor musí hodnotu nahradit skutečným číslem PR. `null` nesplňuje běžný formát ani podmínku G12. Bootstrap PR musí obsahovat marker `<!-- retro: none bootstrap -->`; marker a jeho potvrzení se řídí ADR 0019.

### Mechanická kontrola G12

G12 ověřuje přidání regular souboru v rozdílu pevných merge-base a head trees, přesnou cestu a všech pět polí frontmatter podle tabulky. Obsah musí být UTF-8; úvodní BOM je povolený. Hodnoty `issue` a `pr` musí být kladná celá čísla v desítkovém zápisu bez uvozovek. G12 porovnává `pr` s číslem PR a datum i session s názvem souboru. Existující upravený soubor nestačí.

G12 nekontroluje strukturu těla dokumentu ani pravdivost důkazů. Agent `session-retro` musí dodat celý dokument podle následujících sekcí; kontrola metadat tuto povinnost nenahrazuje. Pravidla výjimky a potvrzení koordinátorem určuje sekce [Merge gate v AGENTS.md](../../../AGENTS.md#merge-gate).

## Struktura dokumentu

Za frontmatter musí následovat nadpis `# Retrospektiva session`, sekce `## Rozsah a zdroje` a sekce `## Nálezy`.

`## Rozsah a zdroje` musí uvést:

- použitý zdroj záznamu, identitu cílové session a prohledaný časový rozsah;
- způsob ověření a pokrytí konverzace, žádostí nástrojů a jejich výsledků;
- omezení zdroje, nedočtené stránky nebo chybějící části;
- rozdíl mezi ověřeným faktem, nahlášeným faktem a neověřeným stavem.

Záznam právě běžící session může končit okamžikem sběru. Agent musí tento konec uvést a nesmí tvrdit, že ověřil pozdější CI, review nebo handoff.

### Nález

Každý nález musí mít vlastní nadpis `### R<N>: <stručný název>` a tato čtyři pole:

```markdown
### R1: Hledání bez omezení adresáře

- **Kategorie:** selhaný příkaz nebo nástroj
- **Důkaz:** Ověřeno v záznamu nástroje: neomezený glob skončil timeoutem; následná kontrola dvou známých cest uspěla. Odkaz: příkaz `Test-Path`, cílový soubor `SKILL.md`.
- **Cena:** 2 volání nástrojů, z toho 1 neúspěšné.
- **Navržené pravidlo:** Před rekurzivním hledáním skillu ověř jeho známé kořeny.
```

Příklad nálezu je syntetický. Skutečný důkaz musí obsahovat dohledatelný odkaz na soubor, příkaz, commit nebo pořadí události/turnu v označeném zdroji. Odkaz na zdrojový kód má použít cestu relativní k repozitáři a případně commit SHA. Soukromý záznam může mít logický lokátor, například `SDK event log, události 12–15`, bez zveřejnění konverzace.

`Cena` musí vyjádřit pozorovaný počet volání nebo opakování a jeho jednotku. Agent musí uvést, co počítal; při neúplném záznamu uvede doloženou dolní mez. Agent nesmí odhad vydávat za naměřenou cenu. `Navržené pravidlo` musí pojmenovat aktéra nebo situaci a konkrétní krok.

### Kategorie

Hodnota `Kategorie` musí přesně odpovídat jedné z těchto pěti hodnot:

| Hodnota | Co agent hledá |
|---|---|
| `hledání faktu` | Zjišťování faktu a opakované hledání stejného faktu bez změny stavu. |
| `chybný předpoklad` | Předpoklad vyvrácený záznamem a kroky potřebné k jeho opravě. |
| `selhaný příkaz nebo nástroj` | Neúspěšné volání, timeout, nenulový exit code nebo chybný postup práce s nástrojem. |
| `oprava od uživatele` | Oprava předchozího postupu nebo tvrzení agentů uživatelem. Nový požadavek ani schválení nejsou oprava. |
| `nález CI nebo review` | Nález validace nebo review a doložený způsob jeho opravy či nevyřešený stav. |

Agent musí prohledat všech pět kategorií. Dokument obsahuje jen doložené nálezy, nikoli povinný nález pro každou kategorii. Pokud úplně přečtený záznam neobsahuje žádný nález, sekce `## Nálezy` musí obsahovat `Žádné doložené nálezy.` a zdroj musí doložit kontrolu všech kategorií. Nedostupný záznam není tento případ: agent musí nahlásit blokující omezení a retrospektivu nevytvořit.

## Obsah pro veřejný repozitář

- Agent musí nálezy parafrázovat. Nesmí kopírovat doslovné citace konverzace, zprávy uživatele ani payloady nástrojů.
- Agent nesmí zapsat data instance podle [ADR 0012](../../adr/0012-public-source-repository.md), osobní údaje, přihlašovací údaje, soukromé URL ani absolutní cesty obsahující uživatelské či strojové údaje. Požadované ID session a odkazy na veřejný zdrojový kód slouží jako technické lokátory.
- Agent musí oddělit pozorování od návrhu pravidla. Rozpor návrhu s `AGENTS.md`, ADR nebo existujícím průvodcem musí označit; nesmí existující pravidlo změnit.
- Agent nesmí zdrojový záznam ani kopii konverzace commitnout. Uchová jen sanitizované nálezy a jejich lokátory.

## Zdroje záznamu a fallback

1. Agent musí nejprve použít read-only nástroj `session_store_sql`. Musí vyřešit mapování ID session, číst její chronologické turny a spojit volání nástrojů s výsledky. Dotazy musí omezit na cílovou session, časový rozsah a stránky. Neúspěšný shell může mít vnější stav nástroje `success: true`; agent musí ověřit i exit code a výstup příkazu.
2. Pokud SQL nástroj chybí nebo záznam nevrátí, agent může pro cloud task použít GitHub MCP `get_copilot_task_status` a potom `get_copilot_session_events`. Musí vzít skutečné task UUID ze známé task URL a vybrat odpovídající `session_id` z výsledku statusu. App ID ani automation ID nesmí vydávat za cloud task ID. Nástroje musí nejprve objevit v dostupném runtime.
3. Agent musí přečíst všechny stránky událostí přes `page_number`/`next_page_number`, nebo pokračovat přes vrácený kurzor `next_after` v parametru `after`. Tyto režimy nesmí smíchat. Počet `total` není důkazem ukončení session. Chybu oprávnění, limitu velikosti nebo chybějící stránku musí uvést jako omezení, nikoli jako prázdný záznam.
4. Pro lokální app session bez cloud task ID může agent číst její vlastní SDK `events.jsonl` v úložišti session, pokud k němu má oprávnění. Musí ověřit ID z události `session.start`, číst chronologický záznam a uvést tento zdroj místo SQL. Nesmí hledat v cizích session ani kopírovat záznam do repozitáře.
5. Pokud žádný zdroj neposkytne čitelný záznam, agent musí vrátit blokující omezení. Sebereflexe implementátora není fallback.

### Stav ověření k 6. 11. 2026

- **Ověřeno:** lokální implementační běh má nástroj `session_store_sql`. Dotazy na ID koordinující session v cloud i local zdroji vrátily 0 řádků. To dokládá nedostupnost konkrétního záznamu přes provedené dotazy, nikoli nedostupnost všech záznamů.
- **Ověřeno:** SDK `events.jsonl` koordinující session existuje; jeho `session.start` obsahuje shodné ID. První ukázka proto používá tento lokální záznam.
- **Ověřeno:** discovery GitHub MCP poskytlo schéma nástrojů `get_copilot_task_status` a `get_copilot_session_events`, včetně parametrů stránkování. Získání záznamu konkrétní cloud session tímto fallbackem nebylo provedeno.
- **Neověřeno:** dostupnost `session_store_sql` uvnitř cloud execution a funkčnost MCP fallbacku pro konkrétní cloud task. Tento běh není cloud execution. Označení `_query_source: cloud` ve výsledku SQL samo o sobě cloud execution neprokazuje.
