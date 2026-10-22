# Rulesety používají izolovaný Terraform root v modulu

Modul s výjimkou `rulesetPlan` podle ADR 0016 umístí všechny spravované rulesety včetně bypass konfigurace do rootu `rulesets/`. Root má state key `terraform.rulesets.tfstate` ve stejném kontejneru modulu; běžný root zachová `terraform.tfstate`. Jde o výjimku z jednoho rootu a state podle ADR 0006, nikoli o nový Module (modul).

Read-only plan běžného rootu nedostane ruleset klíč ani token. Samostatný ruleset plan plánuje celý izolovaný root bez `-target` a bez dalšího schválení. Apply job modulu po schválení použije apply identitu na oba rooty; u `organization-rulesets` zůstává další schválení security týmem. Závislý modul dostane výstupy až po úspěchu obou rootů.

Doplněk ([#73](https://github.com/msucharda/devsecops-platform/issues/73)): root `rulesets/` přesunul uživatel z modulu `enterprise-baseline` do samostatného modulu `organization-rulesets`. `actions-catalog` vyžaduje ruleset organizace akcí před svým apply a `enterprise-baseline` závisí na `actions-catalog` kvůli politice akcí ([#18](https://github.com/msucharda/devsecops-platform/issues/18)). Ruleset v `enterprise-baseline` by proto vytvořil cyklus. Pořadí je `organizations` → `organization-rulesets` → `actions-catalog` → `enterprise-baseline`. Rozhodnutí tohoto ADR platí beze změny i pro nový modul.

Jeden společný root by při refreshi vyžadoval write credential i pro běžný plan. Targetované plány jednoho společného state jsme odmítli, protože mohou vynechat změny pravidel nebo bypassu. Rozdělený state vyžaduje, aby bootstrap přidělil ruleset plan identitě pouze čtení state modulu a aby odstranění instance odstranilo oba rooty.
