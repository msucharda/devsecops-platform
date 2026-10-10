# Nastavení bez Terraform resource spravuje generic REST provider

Nastavení GitHubu, pro které provider `integrations/github` nemá resource, spravuje Terraform přes generic REST provider (například `Mastercard/restapi`), pokud API podporuje installation tokeny podle ADR 0016. Týká se to například organizačních rulesetů, code security configurations a custom patterns pro secret scanning. Terraform tak detekuje drift automatizovaných nastavení. Nastavení bez veřejného API pro zápis nebo bez podpory installation tokenů popisuje ruční checklist modulu s omezením planu, driftu a teardownu. Patří sem například většina politik Copilotu a konfigurace enterprise audit-log streamu.

## Considered Options

- Skripty volající REST API (`gh api`, PowerShell). Zamítnuto: Skript nezná předchozí stav, takže nedetekuje drift a neodstraní nastavení při teardownu.
- Čekat na resource v `integrations/github`. Zamítnuto: Platforma by nevynucovala klíčové kontroly.
