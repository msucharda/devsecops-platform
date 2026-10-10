# Platforma má vlastní bootstrap místo ALZ acceleratoru

Platformní tým spustí bootstrap jednou lokálně. Bootstrap vytvoří state backend, identity pro plan a apply a repozitář s konfigurací instance v organizaci platformy. Ostatní moduly nasazuje GitHub Actions přes chráněná environmenty pro plan a apply. Modul SLZ volá `avm-ptn-alz` s knihovnou `platform/slz` přímo, bez bootstrapu ALZ acceleratoru.

## Considered Options

- Bootstrap ALZ acceleratoru. Zamítnuto: Accelerator vyžaduje dva PAT, generuje vlastní repozitář a workflow ze šablony a pokrývá jen landing zone. Platforma nasazuje i enterprise GitHubu a zákazník přebírá moduly z release, ne z vygenerované šablony.
- Nasazení všech modulů lokálně. Zamítnuto: Změna instance by neprošla PR a schválením.

## Consequences

- Setup user enterprise EMU smí podle dokumentace GitHubu jen konfigurovat autentizaci a provisioning, ne vytvářet organizace. Bootstrap proto spouští člen platformního týmu, kterému administrátor Entra ID přímo přiřadil app roli Enterprise Owner. Bootstrap používá jeho OAuth token z `gh auth login`.
- Modul `emu-identity` přiřadí roli Enterprise Owner skupině platformního týmu. Ruční krok pak odebere přímé přiřazení.
- Enterprise kontroly z ADR 0016 musí platit před bootstrapem a teardown je zachová. První založení enterprise-owned GitHub Apps a vložení jejich klíčů mohou být řízené ruční kroky bootstrapu.
