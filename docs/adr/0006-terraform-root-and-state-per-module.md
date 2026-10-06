# Každý modul má vlastní Terraform root a state

Každý modul je samostatný Terraform root s vlastním state. Modul čte výstupy svých předpokladů ze state předpokladů. Chyba v jednom modulu tak nezablokuje plan ostatních modulů a identita modulu potřebuje oprávnění jen na své prostředky.

## Considered Options

- Jeden root pro celou instanci. Zamítnuto: Každý plan by načítal stav celé instance a identita pro apply by potřebovala oprávnění na enterprise GitHubu i na celou SLZ.

## Consequences

- Workflow nasazení instance musí spouštět moduly v pořadí závislostí.
- Změna výstupu modulu je změna rozhraní pro závislé moduly.
