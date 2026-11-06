# Model routing

Tento soubor je jediný zdroj výchozího routingu pro tento repozitář.
Skills a profily na něj odkazují; tabulku nekopírují. Uživatel může pro
konkrétní práci výslovně zvolit jiný model nebo reasoning.

| Práce | Model | Reasoning |
|---|---|---|
| Návrh s uživatelem, spec, tickets, samostatný návrh řešení | `claude-opus-5.5` | `high` |
| Implementace, testy, dokumentace a opravy | `gpt-6.1-sol` | `high` |
| Nezávislá analýza existujícího kódu | `gpt-6-astra` | `high` |
| Standardní code review | `gpt-6.1-sol` | výchozí |
| Security checkpoint implementace na GPT | `claude-opus-5.5` | `high` |
| Security checkpoint implementace na Opus | `gpt-6.1-sol` | výchozí |

Při spouštění session nebo subagenta nastav model výslovně. Pro `high` nastav
i `reasoning_effort`; u výchozího reasoning parametr vynech, nepředávej
nepodporovaný literál `default`. Typ subagenta s runtime-vynuceným modelem
si ponechá svůj model. Pokud tím nelze dodržet nezávislost checkpointu,
oznam omezení místo tvrzení, že checkpoint proběhl.

Security checkpoint musí mít čerstvý kontext a jinou modelovou rodinu než
implementátor. Při jiné implementační rodině vyber jinou dostupnou rodinu
z tabulky; při neznámém implementátorovi nejdřív ověř jeho identitu.

`xhigh` není automatický režim celého workflow. Použij ho při výslovném zadání
nebo po schválení eskalace konkrétní nevyřešené otázky.

U ručně otevřené session model vybírá uživatel. Skill nemění runtime model
a agent nesmí tvrdit, že ho přepnul. Odlišný model aktuální session není sám
o sobě důvodem založit další session; explicitní volbu uživatele zachovej.
