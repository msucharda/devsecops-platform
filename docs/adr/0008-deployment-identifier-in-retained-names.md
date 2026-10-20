# Prostředky s blokovaným názvem po smazání mají v názvu identifikátor nasazení

Azure prostředky a organizace GitHubu, jejichž název zůstává po smazání blokovaný, mají v názvu identifikátor nasazení. Patří sem například Key Vault s purge protection a všechny organizace instance. Ostatní prostředky mají stabilní názvy. Purge protection zůstává zapnutá. Teardown a nové nasazení instance tak nečekají na konec retence ani na uvolnění názvu organizace.

## Organizace GitHubu

Organizace instance mají názvy `{name}-{deployment}-platform`, `{name}-{deployment}-actions` a `{name}-{deployment}-workloads`. `{name}` je `instance.name`, `{deployment}` je identifikátor nasazení. Teardown smaže organizace akcí a workloadů. Lokální odstranění bootstrapu smaže organizaci platformy (#22). Nové vytvoření organizace po jejím smazání musí použít nový identifikátor nasazení. Formát identifikátoru a jeho uložení určí implementace (#44, #13). Bootstrap vytvoří 6 náhodných znaků `[a-z0-9]` a uloží je v bootstrap inventory (`docs/bootstrap.md`).

Ověření 75 (#5) na referenční enterprise na GHE.com:

- 13. 10. 2026 autor vytvořil organizaci `testorg`, smazal ji bez předchozího přejmenování a ihned zkusil vytvořit organizaci se stejným názvem. GitHub vytvoření odmítl zprávou `The name 'testorg' is already taken.`
- 20. 10. 2026, po 7 dnech, GitHub odmítl vytvoření stejnou zprávou. REST API vrátilo pro organizaci HTTP 404, pro účet se stejným názvem vrátilo záznam typu Organization.

Výsledek: GHE.com název smazané organizace neuvolní okamžitě ani do 7 dní. Doba uvolnění na GHE.com není známá. Na github.com GitHub blokuje název smazané organizace 90 dní.

## Considered Options

- Stabilní názvy a purge při teardownu. Zamítnuto: Purge protection purge nedovolí a její vypnutí oslabí ochranu dat.
- Identifikátor nasazení ve všech názvech. Zamítnuto: Názvy by se měnily bez důvodu a odkazy mimo Terraform by se rozbily.
- Stabilní názvy organizací a čekání na uvolnění názvu. Zamítnuto: Doba uvolnění je neznámá a delší než 7 dní. Nové nasazení po teardownu by selhalo.
- Přejmenování organizace před smazáním. Zamítnuto: Uvolnění původního názvu po přejmenování není na GHE.com ověřené. Teardown přerušený mezi přejmenováním a smazáním zanechá organizaci s jiným názvem.

## Consequences

- Název organizace nejde odvodit jen z `instance.name`. Bootstrap, moduly a nástroje musí používat skutečný název organizace. Bootstrap a nástroje pro organizaci platformy upraví #44. Modul `organizations` použije vzor pro organizace akcí a workloadů (#13).
- Odkazy na organizace mimo Terraform, například CODEOWNERS nebo `target_organizations`, se po teardownu a novém nasazení změní.
