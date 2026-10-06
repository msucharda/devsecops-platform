# Prostředky s retencí po smazání mají v názvu identifikátor nasazení

Azure prostředky, jejichž název zůstává po smazání blokovaný (například Key Vault s purge protection), mají v názvu identifikátor nasazení. Ostatní prostředky mají stabilní názvy. Purge protection zůstává zapnutá. Teardown a nové nasazení instance tak nečeká na konec retence.

## Considered Options

- Stabilní názvy a purge při teardownu. Zamítnuto: Purge protection purge nedovolí a její vypnutí oslabí ochranu dat.
- Identifikátor nasazení ve všech názvech. Zamítnuto: Názvy by se měnily bez důvodu a odkazy mimo Terraform by se rozbily.

## Consequences

- První test teardownu musí ověřit, jestli GitHub dovolí znovu použít název smazané organizace.
