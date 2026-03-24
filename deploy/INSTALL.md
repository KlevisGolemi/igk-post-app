# Postra - Guide d'installation complet

> Ce guide permet d'installer Postra sur un VPS Ubuntu depuis zero.
> Temps estime : 20-30 minutes.

---

## Table des matieres

1. [Pre-requis](#1-pre-requis)
2. [Architecture](#2-architecture)
3. [Configurer le DNS](#3-configurer-le-dns)
4. [Preparer le serveur](#4-preparer-le-serveur)
5. [Installation automatique (recommande)](#5-installation-automatique)
6. [Installation manuelle](#6-installation-manuelle)
7. [Post-installation](#7-post-installation)
8. [Maintenance](#8-maintenance)
9. [Troubleshooting](#9-troubleshooting)
10. [Reference des variables](#10-reference-des-variables)

---

## 1. Pre-requis

### Serveur

| Composant | Minimum | Recommande |
|-----------|---------|------------|
| RAM | 4 GB | 8 GB |
| CPU | 2 coeurs | 4 coeurs |
| Disque | 20 GB SSD | 40 GB SSD |
| OS | Ubuntu 22.04+ | Ubuntu 24.04 LTS |

### Comptes necessaires

| Service | Pourquoi | Lien |
|---------|----------|------|
| **GitHub** | Heberge le code et l'image Docker | https://github.com |
| **Cloudflare** | Stockage media (R2) | https://dash.cloudflare.com |
| **Registrar DNS** | Pointer le domaine vers le VPS | (votre fournisseur) |

### Informations a preparer

Avant de commencer, rassemblez :

- [ ] L'adresse IP de votre VPS
- [ ] Le nom de domaine (ex: `postra.igk-digital.cloud`)
- [ ] L'acces SSH root au serveur
- [ ] Les identifiants Cloudflare R2 (Account ID, Access Key, Secret Key, Bucket name, Bucket URL)
- [ ] (Optionnel) Les cles API des reseaux sociaux que vous souhaitez connecter

---

## 2. Architecture

Postra est compose de 8 services Docker :

```
                                    Internet
                                       |
                                  [ Traefik ]
                                  HTTPS (443)
                                       |
                              +--------+--------+
                              |   postra.domain  |
                              |   port 5000      |
                              +--------+--------+
                                       |
                    +------------------+------------------+
                    |                  |                  |
              [ nginx :5000 ]         |                  |
              /api/ -> :3000          |                  |
              /    -> :4200           |                  |
                    |                 |                  |
           +-------+-------+  +------+------+  +-------+-------+
           |   Backend     |  |  Frontend   |  | Orchestrator  |
           |   (NestJS)    |  |  (Next.js)  |  | (NestJS +     |
           |   :3000       |  |  :4200      |  |  Temporal)    |
           +-------+-------+  +-------------+  +-------+-------+
                   |                                    |
          +--------+--------+               +-----------+-----------+
          |                 |               |                       |
    [ PostgreSQL ]    [ Redis ]       [ Temporal Server ]           |
      postiz-db       cache/queue      :7233                       |
                                           |                       |
                                  +--------+--------+              |
                                  |                 |              |
                            [ Temporal    ]   [ Temporal    ]      |
                            [ PostgreSQL  ]   [ Elastic-    ]      |
                            [             ]   [ search      ]      |
                            +-------------+   +-------------+      |
                                                                   |
                                                          [ Temporal UI ]
                                                          127.0.0.1:8080
```

### Services et reseaux

| Service | Role | Reseau |
|---------|------|--------|
| **postiz** | Application principale (frontend + backend + orchestrator) | postiz, temporal, traefik |
| **postiz-postgres** | Base de donnees de l'application | postiz |
| **postiz-redis** | Cache et file d'attente | postiz |
| **temporal** | Serveur de workflows (planification des posts) | temporal |
| **temporal-postgresql** | Base de donnees de Temporal | temporal |
| **temporal-elasticsearch** | Recherche pour Temporal | temporal |
| **temporal-admin-tools** | CLI d'administration Temporal | temporal |
| **temporal-ui** | Dashboard Temporal (local uniquement) | temporal |

---

## 3. Configurer le DNS

Avant d'installer, pointez votre domaine vers l'IP du VPS.

### Chez votre registrar DNS (ou Cloudflare DNS) :

Creez un enregistrement **A** :

```
Type : A
Nom  : postra          (ou le sous-domaine choisi)
IP   : 123.456.789.0   (remplacez par l'IP de votre VPS)
TTL  : Auto (ou 300)
```

> **Note Cloudflare** : Si vous utilisez Cloudflare DNS, desactivez le proxy orange
> (passez en "DNS only" / icone grise) le temps de l'installation.
> Traefik a besoin d'acceder directement au serveur pour generer le certificat SSL.
> Vous pourrez reactiver le proxy apres.

### Verifier la propagation DNS

Depuis votre ordinateur :

```bash
# Remplacez par votre domaine
nslookup postra.igk-digital.cloud

# Ou
dig postra.igk-digital.cloud +short
```

Le resultat doit afficher l'IP de votre VPS. La propagation peut prendre 5-30 minutes.

---

## 4. Preparer le serveur

Connectez-vous en SSH :

```bash
ssh root@IP_DU_VPS
```

### 4.1 Mettre a jour le systeme

```bash
apt update && apt upgrade -y
```

### 4.2 Installer Docker (si pas deja installe)

```bash
# Verifier si Docker est deja installe
docker --version

# Si non installe :
curl -fsSL https://get.docker.com | sh

# Verifier l'installation
docker --version
docker compose version
```

> Docker Compose V2 est inclus avec Docker Engine depuis la version 20.10+.
> La commande est `docker compose` (sans tiret), pas `docker-compose`.

### 4.3 Installer les outils necessaires

```bash
apt install -y git curl openssl
```

### 4.4 (Recommande) Creer un utilisateur non-root

```bash
adduser postra
usermod -aG docker postra
su - postra
```

---

## 5. Installation automatique

> C'est la methode recommandee. Le script `deploy.sh` fait tout automatiquement.

### 5.1 Cloner le depot

```bash
git clone --branch igk-branding --depth 1 \
  https://github.com/KlevisGolemi/igk-post-app.git \
  /docker/postra
```

### 5.2 Lancer le script

```bash
bash /docker/postra/deploy/deploy.sh
```

Le script va :
1. Verifier les pre-requis (Docker, RAM, etc.)
2. Detecter ou installer Traefik (reverse proxy HTTPS)
3. Vous demander votre domaine
4. Generer automatiquement les secrets (JWT, mots de passe DB)
5. Vous demander vos identifiants Cloudflare R2
6. Telecharger les images Docker
7. Demarrer tous les services dans le bon ordre
8. Verifier que tout fonctionne

### 5.3 Resultat attendu

Si tout va bien, vous verrez :

```
==========================================
  Postra deployment complete!
==========================================

  App URL:         https://postra.igk-digital.cloud
  Temporal UI:     http://127.0.0.1:8080 (SSH tunnel required)

  Env file:        /docker/postra/deploy/.env
  Compose file:    /docker/postra/deploy/docker-compose.prod.yaml
```

> **Passez directement a la section [7. Post-installation](#7-post-installation).**

---

## 6. Installation manuelle

> Suivez cette section si vous preferez controler chaque etape,
> ou si le script automatique a echoue.

### 6.1 Cloner le depot

```bash
git clone --branch igk-branding --depth 1 \
  https://github.com/KlevisGolemi/igk-post-app.git \
  /docker/postra

cd /docker/postra/deploy
```

### 6.2 Configurer Traefik

Le script `deploy.sh` gere automatiquement la detection de Traefik. En mode manuel,
suivez le cas qui correspond a votre situation :

#### Cas A : Traefik tourne deja sur votre VPS

```bash
# Verifier si un conteneur Traefik existe (quel que soit son nom)
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i traefik
```

Si vous voyez un resultat (ex: `traefik-proxy  traefik:v3.4`), il suffit de :

```bash
# Creer le reseau que Postra utilise
docker network create traefik-network 2>/dev/null || true

# Connecter votre Traefik existant a ce reseau
# (remplacez "traefik" par le nom de votre conteneur)
docker network connect traefik-network traefik

# Verifier la connexion
docker inspect traefik --format='{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# Doit contenir "traefik-network"
```

> **Note** : Cela ne deconnecte PAS Traefik de ses reseaux existants.
> Vos autres applications continueront de fonctionner normalement.

Ensuite, verifiez le nom du **certresolver** dans votre config Traefik :

```bash
# Trouver le nom du certresolver (ex: letsencrypt, mytlschallenge, myresolver...)
docker exec traefik cat /etc/traefik/traefik.yml 2>/dev/null || \
docker exec traefik cat /etc/traefik/traefik.yaml 2>/dev/null
# Cherchez: certificatesResolvers: → le nom juste en dessous

# Mettez ce nom dans votre .env :
# TRAEFIK_CERTRESOLVER=mytlschallenge
```

> **Important** : si le nom ne correspond pas, Traefik servira son certificat par defaut
> au lieu du vrai certificat Let's Encrypt.

#### Cas B : Pas de Traefik, il faut l'installer

```bash
cd /docker/postra/deploy/traefik

# Editer traefik.yaml pour ajouter votre email Let's Encrypt
nano traefik.yaml
```

Ajoutez la ligne `email:` dans la section acme :

```yaml
certificatesResolvers:
  letsencrypt:
    acme:
      email: votre-email@example.com    # <-- Ajoutez cette ligne
      storage: /letsencrypt/acme.json
```

Puis :

```bash
# Creer le reseau et demarrer Traefik
docker network create traefik-network 2>/dev/null || true
docker compose -f docker-compose.traefik.yaml up -d

# Verifier qu'il tourne
docker ps --filter name=traefik
```

#### Cas C : Ports 80/443 deja utilises par un autre proxy

Si un autre reverse proxy (Nginx, Caddy, etc.) occupe les ports 80/443 :

```bash
# Identifier quel conteneur utilise les ports
docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E ':80|:443'
```

Vous avez deux options :
1. **Remplacer** votre proxy par Traefik (arretez l'ancien, installez Traefik)
2. **Garder** votre proxy et configurer un reverse proxy vers le conteneur `postiz` sur le port 5000, puis creer le reseau manuellement :
   ```bash
   docker network create traefik-network
   docker network connect traefik-network <votre-proxy>
   ```

### 6.4 Configurer les variables d'environnement

```bash
cd /docker/postra/deploy

# Copier le template
cp .env.production.template .env

# Editer le fichier
nano .env
```

Remplissez les valeurs suivantes :

**Domaine** (adaptez a votre domaine) :
```
DOMAIN=postra.igk-digital.cloud
MAIN_URL=https://postra.igk-digital.cloud
FRONTEND_URL=https://postra.igk-digital.cloud
NEXT_PUBLIC_BACKEND_URL=https://postra.igk-digital.cloud/api
```

**Secrets** (generez des valeurs uniques) :
```bash
# Generez et copiez ces valeurs dans le .env :
echo "JWT_SECRET=$(openssl rand -base64 48)"
echo "POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)"
echo "TEMPORAL_POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)"
```

**Cloudflare R2** : remplissez les 5 champs `CLOUDFLARE_*` avec vos identifiants.

### 6.5 Telecharger les images Docker

```bash
cd /docker/postra/deploy

# Si l'image GHCR est privee, connectez-vous d'abord :
# (Creez un token sur https://github.com/settings/tokens avec le scope read:packages)
# echo "VOTRE_TOKEN" | docker login ghcr.io -u VOTRE_USERNAME --password-stdin

# Telecharger toutes les images
docker compose -f docker-compose.prod.yaml pull
```

### 6.6 Demarrer les services (par phases)

**Phase 1 : Bases de donnees**

```bash
docker compose -f docker-compose.prod.yaml up -d postiz-postgres postiz-redis

# Attendre qu'elles soient pretes (30 secondes max)
echo "Attente des bases de donnees..."
sleep 10
docker inspect --format='{{.State.Health.Status}}' postiz-postgres
docker inspect --format='{{.State.Health.Status}}' postiz-redis
```

Les deux doivent afficher `healthy`.

**Phase 2 : Temporal**

```bash
docker compose -f docker-compose.prod.yaml up -d temporal-elasticsearch
echo "Attente d'Elasticsearch (30-60s)..."
sleep 30

docker compose -f docker-compose.prod.yaml up -d temporal-postgresql
sleep 10

docker compose -f docker-compose.prod.yaml up -d temporal
echo "Attente de Temporal (30-60s)..."
sleep 30

# Verifier
docker inspect --format='{{.State.Health.Status}}' temporal
```

Doit afficher `healthy`. Si `starting`, attendez encore 30 secondes.

```bash
docker compose -f docker-compose.prod.yaml up -d temporal-admin-tools temporal-ui
```

**Phase 3 : Application**

```bash
docker compose -f docker-compose.prod.yaml up -d postiz

# L'application met 60-90 secondes a demarrer
# (migration base de donnees + demarrage de 3 processus)
echo "Attente de l'application (90s)..."
sleep 90

docker inspect --format='{{.State.Health.Status}}' postiz
```

### 6.7 Verifier le deploiement

```bash
# Verifier que tous les services tournent
docker compose -f docker-compose.prod.yaml ps

# Tester l'URL (remplacez par votre domaine)
curl -I https://postra.igk-digital.cloud

# Voir les logs de l'application
docker compose -f docker-compose.prod.yaml logs postiz --tail 30
```

---

## 7. Post-installation

### 7.1 Creer votre compte

1. Ouvrez `https://postra.igk-digital.cloud` dans votre navigateur
2. Cliquez sur **Register** / **S'inscrire**
3. Remplissez le formulaire
4. Vous etes automatiquement connecte (pas de confirmation email)

### 7.2 Securiser les inscriptions

Apres avoir cree votre compte, desactivez les inscriptions publiques :

```bash
cd /docker/postra/deploy

# Editer .env
nano .env
# Changez : DISABLE_REGISTRATION=true

# Redemarrer l'app (les autres services ne sont pas affectes)
docker compose -f docker-compose.prod.yaml up -d --no-deps postiz
```

### 7.3 Ajouter les cles API des reseaux sociaux

Editez le fichier `.env` et remplissez les cles des reseaux que vous voulez connecter :

```bash
nano /docker/postra/deploy/.env
```

Par exemple pour X (Twitter) :
```
X_API_KEY=votre_cle
X_API_SECRET=votre_secret
```

Puis redemarrez l'application :

```bash
cd /docker/postra/deploy
docker compose -f docker-compose.prod.yaml up -d --no-deps postiz
```

> **Callback URLs** : Pour chaque reseau social, vous devez configurer l'URL de callback
> dans le dashboard developeur du reseau :
> `https://votre-domaine.com/api/auth/PROVIDER/callback`
> (remplacez PROVIDER par : twitter, linkedin, facebook, etc.)

### 7.4 Acceder au dashboard Temporal

Le dashboard Temporal n'est accessible que localement (securite).
Utilisez un tunnel SSH depuis votre ordinateur :

```bash
ssh -L 8080:127.0.0.1:8080 user@IP_DU_VPS
```

Puis ouvrez http://localhost:8080 dans votre navigateur.

---

## 8. Maintenance

### 8.1 Mettre a jour Postra

Quand une nouvelle version est disponible :

```bash
bash /docker/postra/deploy/update.sh
```

Le script :
1. Pull le code le plus recent
2. Telecharge la derniere image Docker
3. Redemarre le conteneur de l'application
4. Verifie que tout fonctionne

> **Downtime** : ~30 secondes pendant le redemarrage.

### 8.2 Backup de la base de donnees

**Backup manuel** :

```bash
# Sauvegarder la base de donnees Postra
docker exec postiz-postgres pg_dump -U postiz -d postiz \
  > /docker/postra/backups/postra_$(date +%Y%m%d_%H%M%S).sql

# Sauvegarder la base Temporal (optionnel)
docker exec temporal-postgresql pg_dump -U temporal -d temporal \
  > /docker/postra/backups/temporal_$(date +%Y%m%d_%H%M%S).sql
```

**Backup automatique (cron)** :

```bash
# Creer le dossier de backups
mkdir -p /docker/postra/backups

# Ajouter un cron job (tous les jours a 3h du matin)
crontab -e
```

Ajoutez cette ligne :

```
0 3 * * * docker exec postiz-postgres pg_dump -U postiz -d postiz > /docker/postra/backups/postra_$(date +\%Y\%m\%d).sql 2>&1
```

**Restaurer un backup** :

```bash
# Arreter l'application d'abord
docker compose -f /docker/postra/deploy/docker-compose.prod.yaml stop postiz

# Restaurer
cat /docker/postra/backups/postra_20260324.sql | \
  docker exec -i postiz-postgres psql -U postiz -d postiz

# Redemarrer
docker compose -f /docker/postra/deploy/docker-compose.prod.yaml up -d postiz
```

### 8.3 Voir les logs

```bash
cd /docker/postra/deploy

# Logs de l'application (temps reel)
docker compose -f docker-compose.prod.yaml logs -f postiz

# Logs d'un service specifique
docker compose -f docker-compose.prod.yaml logs temporal --tail 50

# Logs de tous les services
docker compose -f docker-compose.prod.yaml logs --tail 20
```

### 8.4 Redemarrer un service

```bash
cd /docker/postra/deploy

# Redemarrer seulement l'application
docker compose -f docker-compose.prod.yaml restart postiz

# Redemarrer tout
docker compose -f docker-compose.prod.yaml restart
```

### 8.5 Arreter / Demarrer

```bash
cd /docker/postra/deploy

# Arreter tous les services (les donnees sont conservees)
docker compose -f docker-compose.prod.yaml down

# Redemarrer tous les services
docker compose -f docker-compose.prod.yaml up -d
```

> **ATTENTION** : Ne jamais utiliser `docker compose down -v` — le flag `-v` supprime
> les volumes et donc toutes vos donnees (base de donnees, uploads, etc.) !

### 8.6 Surveiller les ressources

```bash
# Utilisation CPU/RAM de chaque conteneur
docker stats

# Espace disque des volumes
docker system df -v
```

---

## 9. Troubleshooting

### L'application ne demarre pas

**Symptome** : le conteneur `postiz` reste en `starting` ou passe en `unhealthy`.

```bash
# Verifier les logs
docker compose -f docker-compose.prod.yaml logs postiz --tail 50
```

> **Note importante sur les healthchecks** : L'image Postra ne contient ni `curl`, ni `wget`,
> ni `nc`. Le healthcheck utilise `ss -lnt | grep -q ':5000'` pour verifier que le port 5000
> est en ecoute. Si vous modifiez le healthcheck, n'utilisez pas `curl`.

**Causes possibles** :

| Message dans les logs | Cause | Solution |
|----------------------|-------|----------|
| `ECONNREFUSED ...5432` | PostgreSQL pas pret | Attendre ou redemarrer : `docker compose restart postiz-postgres` |
| `ECONNREFUSED ...6379` | Redis pas pret | `docker compose restart postiz-redis` |
| `ECONNREFUSED ...7233` | Temporal pas pret | `docker compose restart temporal` |
| `JWT_SECRET not set` | Variable manquante | Verifier le fichier `.env` |
| `prisma...migration failed` | Probleme schema DB | Verifier `DATABASE_URL` dans `.env` |
| `Error: listen EADDRINUSE` | Port deja utilise | Verifier : `docker ps` pour les conteneurs conflictuels |

### Impossible d'acceder au site (timeout)

1. **Verifier le DNS** :
   ```bash
   dig postra.igk-digital.cloud +short
   ```
   Doit retourner l'IP de votre VPS.

2. **Verifier Traefik** :
   ```bash
   docker ps --filter name=traefik
   docker logs traefik --tail 20
   ```

3. **Verifier les ports** :
   ```bash
   # Les ports 80 et 443 doivent etre ouverts
   ss -tlnp | grep -E ':80|:443'
   ```

4. **Verifier le firewall** :
   ```bash
   ufw status
   # Si actif, ouvrir les ports :
   ufw allow 80/tcp
   ufw allow 443/tcp
   ```

### Erreur SSL / certificat

**Symptome** : navigateur affiche "votre connexion n'est pas privee" ou le certificat
affiche "TRAEFIK DEFAULT CERT" au lieu de Let's Encrypt.

```bash
# Verifier les logs Traefik
docker logs traefik --tail 30 | grep -i acme

# Verifier le certificat servi
curl -Iv https://votre-domaine.com 2>&1 | grep -i 'issuer\|subject'
```

**Causes possibles** :
- Le DNS ne pointe pas encore vers le VPS → attendez la propagation
- Le proxy Cloudflare est active (icone orange) → passez en "DNS only" (grise)
- Le port 80 est bloque → `ufw allow 80/tcp`
- Rate limit Let's Encrypt → attendez 1 heure et reessayez
- **Mauvais nom de certresolver** → le label `traefik.http.routers.postra.tls.certresolver`
  doit correspondre au nom defini dans votre config Traefik. Verifiez avec :
  ```bash
  # Voir le nom du certresolver dans la config Traefik
  docker exec traefik cat /etc/traefik/traefik.yml 2>/dev/null || \
  docker exec traefik cat /etc/traefik/traefik.yaml 2>/dev/null
  # Cherchez la section certificatesResolvers: → le nom juste en dessous
  # Puis mettez a jour TRAEFIK_CERTRESOLVER dans votre .env
  ```

### Erreur 502 Bad Gateway

Traefik ne peut pas joindre l'application.

```bash
# Verifier que le conteneur est en marche
docker ps --filter name=postiz

# Verifier le healthcheck
docker inspect --format='{{.State.Health.Status}}' postiz

# Verifier que le conteneur est sur le bon reseau
docker network inspect traefik-network
```

### Temporal ne demarre pas

```bash
# Verifier les logs Temporal
docker compose -f docker-compose.prod.yaml logs temporal --tail 30

# Verifier Elasticsearch
docker inspect --format='{{.State.Health.Status}}' temporal-elasticsearch

# Verifier PostgreSQL Temporal
docker inspect --format='{{.State.Health.Status}}' temporal-postgresql
```

> **Note** : Le healthcheck de Temporal utilise `temporal operator cluster health --address temporal:7233`.
> L'adresse doit etre `temporal:7233` (nom du service Docker), pas `localhost:7233`.
> L'ancienne commande `tctl cluster health` est depreciee.

**Causes courantes** :
- Elasticsearch manque de memoire :
  ```bash
  free -h
  docker stats --no-stream
  ```
- Temporal PostgreSQL n'est pas pret → verifier son healthcheck avant de demarrer Temporal

### L'image Docker ne peut pas etre telechargee

```bash
# Erreur: "denied" ou "not found"

# Si l'image est privee, connectez-vous :
echo "VOTRE_TOKEN" | docker login ghcr.io -u VOTRE_USERNAME --password-stdin

# Puis re-essayez :
docker pull ghcr.io/klevisgolemi/igk-post-app:latest
```

Pour creer un token : https://github.com/settings/tokens/new (scope: `read:packages`)

Pour rendre l'image publique : GitHub > votre repo > Packages > Settings > Change visibility > Public

### Reinitialiser completement

> **ATTENTION** : Ceci supprime toutes les donnees !

```bash
cd /docker/postra/deploy

# Arreter et supprimer les conteneurs + volumes
docker compose -f docker-compose.prod.yaml down -v

# Supprimer le .env
rm .env

# Relancer l'installation
bash /docker/postra/deploy/deploy.sh
```

---

## 10. Reference des variables

### Variables obligatoires

| Variable | Description | Exemple |
|----------|-------------|---------|
| `DOMAIN` | Nom de domaine | `postra.igk-digital.cloud` |
| `MAIN_URL` | URL principale (avec https://) | `https://postra.igk-digital.cloud` |
| `FRONTEND_URL` | URL du frontend (= MAIN_URL) | `https://postra.igk-digital.cloud` |
| `NEXT_PUBLIC_BACKEND_URL` | URL de l'API | `https://postra.igk-digital.cloud/api` |
| `JWT_SECRET` | Secret pour les tokens JWT | (genere automatiquement) |
| `POSTGRES_USER` | Utilisateur PostgreSQL | `postiz` |
| `POSTGRES_PASSWORD` | Mot de passe PostgreSQL | (genere automatiquement) |
| `POSTGRES_DB` | Nom de la base de donnees | `postiz` |
| `TEMPORAL_POSTGRES_PASSWORD` | Mot de passe PostgreSQL Temporal | (genere automatiquement) |
| `STORAGE_PROVIDER` | Fournisseur de stockage | `cloudflare` ou `local` |
| `TRAEFIK_CERTRESOLVER` | Nom du certresolver Traefik (auto-detecte par deploy.sh) | `letsencrypt` |

### Variables Cloudflare R2

| Variable | Description |
|----------|-------------|
| `CLOUDFLARE_ACCOUNT_ID` | ID de votre compte Cloudflare |
| `CLOUDFLARE_ACCESS_KEY` | Cle d'acces R2 |
| `CLOUDFLARE_SECRET_ACCESS_KEY` | Cle secrete R2 |
| `CLOUDFLARE_BUCKETNAME` | Nom du bucket R2 |
| `CLOUDFLARE_BUCKET_URL` | URL du bucket (ex: `https://xxx.r2.cloudflarestorage.com/`) |
| `CLOUDFLARE_REGION` | Region (`auto` par defaut) |

### Variables reseaux sociaux

Chaque reseau necessite un couple client ID / secret. Creez une app sur le portail developeur
de chaque reseau et renseignez les valeurs dans le `.env`.

| Reseau | Variables | Portail developeur |
|--------|-----------|-------------------|
| X (Twitter) | `X_API_KEY`, `X_API_SECRET` | https://developer.x.com |
| LinkedIn | `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` | https://developer.linkedin.com |
| Facebook/Instagram | `FACEBOOK_APP_ID`, `FACEBOOK_APP_SECRET` | https://developers.facebook.com |
| Threads | `THREADS_APP_ID`, `THREADS_APP_SECRET` | https://developers.facebook.com |
| YouTube | `YOUTUBE_CLIENT_ID`, `YOUTUBE_CLIENT_SECRET` | https://console.cloud.google.com |
| TikTok | `TIKTOK_CLIENT_ID`, `TIKTOK_CLIENT_SECRET` | https://developers.tiktok.com |
| Reddit | `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET` | https://www.reddit.com/prefs/apps |
| Pinterest | `PINTEREST_CLIENT_ID`, `PINTEREST_CLIENT_SECRET` | https://developers.pinterest.com |
| Discord | `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, `DISCORD_BOT_TOKEN_ID` | https://discord.com/developers |
| Slack | `SLACK_ID`, `SLACK_SECRET`, `SLACK_SIGNING_SECRET` | https://api.slack.com/apps |
| Mastodon | `MASTODON_URL`, `MASTODON_CLIENT_ID`, `MASTODON_CLIENT_SECRET` | Votre instance Mastodon > Preferences > Development |
| Dribbble | `DRIBBBLE_CLIENT_ID`, `DRIBBBLE_CLIENT_SECRET` | https://dribbble.com/account/applications |
| GitHub | `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET` | https://github.com/settings/developers |

> **Callback URL** pour chaque reseau :
> `https://votre-domaine.com/api/auth/PROVIDER/callback`

### Variables optionnelles

| Variable | Description | Defaut |
|----------|-------------|--------|
| `DISABLE_REGISTRATION` | Bloquer les nouvelles inscriptions | `false` |
| `OPENAI_API_KEY` | Cle API OpenAI (generation de contenu IA) | vide |
| `API_LIMIT` | Limite de requetes API par heure | `30` |
| `RESEND_API_KEY` | Cle Resend (emails transactionnels) | vide (inscriptions sans confirmation) |
| `STRIPE_PUBLISHABLE_KEY` | Cle publique Stripe (paiements) | vide |
| `STRIPE_SECRET_KEY` | Cle secrete Stripe | vide |

---

## Commandes utiles - aide-memoire

```bash
# Emplacement des fichiers
/docker/postra/deploy/.env                    # Configuration
/docker/postra/deploy/docker-compose.prod.yaml # Services Docker

# Etat des services
cd /docker/postra/deploy
docker compose -f docker-compose.prod.yaml ps

# Logs en temps reel
docker compose -f docker-compose.prod.yaml logs -f postiz

# Redemarrer l'app apres modif du .env
docker compose -f docker-compose.prod.yaml up -d --no-deps postiz

# Mise a jour
bash /docker/postra/deploy/update.sh

# Backup base de donnees
docker exec postiz-postgres pg_dump -U postiz -d postiz > backup.sql

# Surveillance ressources
docker stats

# Temporal UI (via tunnel SSH depuis votre PC)
ssh -L 8080:127.0.0.1:8080 user@IP_DU_VPS
# puis ouvrir http://localhost:8080
```
