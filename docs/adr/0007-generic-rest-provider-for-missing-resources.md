# Nastavení bez Terraform resource spravuje generic REST provider

Nastavení GitHubu, pro které provider `integrations/github` nemá resource, spravuje Terraform přes generic REST provider (například `Mastercard/restapi`). Týká se to například enterprise rulesetů, code security configurations, custom patterns pro secret scanning a streamování audit logu. Terraform tak detekuje drift u všech nastavení stejně. Nastavení bez veřejného API pro zápis (například politiky Copilotu) popisuje ruční checklist modulu.

## Considered Options

- Skripty volající REST API (`gh api`, PowerShell). Zamítnuto: Skript nezná předchozí stav, takže nedetekuje drift a neodstraní nastavení při teardownu.
- Čekat na resource v `integrations/github`. Zamítnuto: Platforma by nevynucovala klíčové kontroly.
