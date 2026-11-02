<div align="center">

# 🛠️ 58TM1 Infrastructure Toolkit

### Office · RDS · FSLogix

**Diagnostiquer la connexion Office, cibler la réparation et conserver un retour arrière.**

Application Windows portable et moteur PowerShell destinés aux spécialistes informatique, aux administrateurs systèmes et aux équipes infrastructure.

![Version](https://img.shields.io/badge/version-0.2.0_pilote-F59E0B)
![Application](https://img.shields.io/badge/Windows-EXE_x64-0078D4)
![Framework](https://img.shields.io/badge/.NET_Framework-4.8-512BD4)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1_64_bits-5391FE)

**[Démarrage](#demarrage) · [Fonctionnalités](#fonctionnalites) · [Réparations](#reparations) · [Déploiement](#deploiement) · [Restauration](#restauration) · [Documentation](#documentation)**

</div>

---

> [!NOTE]
> **Version 0.2.0 pilote.** L’EXE est compilé ; la logique et les ressources intégrées ont été vérifiées sous Linux. L’interface, l’UAC et les réparations réelles restent à valider sur Windows/RDS. Le tag `58TM1` ne désigne pas, à lui seul, une cause unique.

<a id="demarrage"></a>

## 🚀 Démarrage rapide

### Application Windows — `58TM1.exe`

1. Ouvrir **`58TM1.exe` normalement**, dans la session de l’utilisateur concerné.
2. Choisir **Auto**, **RDS** ou **RDS + FSLogix**.
3. Sélectionner l’action et les options nécessaires.
4. Conserver **Simulation**, ou la décocher pour appliquer.
5. Exécuter, consulter les sorties dans la fenêtre et exporter le journal si besoin.

| À savoir | Détail |
| --- | --- |
| **Format** | EXE portable Windows 64 bits. |
| **Prérequis** | .NET Framework 4.8 et Windows PowerShell 5.1. |
| **Contenu intégré** | Moteur PowerShell et documentation ; aucun téléchargement au lancement. |
| **Élévation** | UAC uniquement pour les actions administrateur. |
| **Parcours professionnel** | Choix explicite du périmètre et du mode d’exécution, sans confirmation répétée. |
| **Distribution** | EXE et scripts non signés ; politiques de l’organisation applicables. |

Les vérifications préalables relèvent du technicien. Le moteur conserve ses contrôles de contexte, de sauvegarde et de périmètre. Voir le [guide de l’application](docs/DESKTOP.md) pour l’élévation et la distribution interne.

<details>
<summary><strong>Alternative : interface du kit PowerShell</strong></summary>

Extraire tous les fichiers du kit dans un dossier local, puis ouvrir **`Start-58TM1.cmd`** depuis la session concernée. Choisir l’environnement et l’action. La simulation est activée par défaut dans cette interface également. Aucun module supplémentaire n’est à installer.

</details>

<details>
<summary><strong>Alternative : utilisation en ligne de commande</strong></summary>

Ouvrir **Windows PowerShell 5.1 — 64 bits** dans le dossier du kit, avec l’utilisateur affecté.

```powershell
# Diagnostic : rapport local, aucune modification de configuration.
.\Repair-58TM1.ps1 -Environment RDSFSLogix

# Simulation de la réparation, après fermeture d’Office.
.\Repair-58TM1.ps1 -Mode RepairUser -Environment RDSFSLogix -WhatIf

# Application de la réparation de base.
.\Repair-58TM1.ps1 -Mode RepairUser -Environment RDSFSLogix

# Test HTTPS anonyme des métadonnées Microsoft Entra.
.\Repair-58TM1.ps1 -TestNetwork

# Réenregistrement forcé du Broker.
.\Repair-58TM1.ps1 -Mode RepairUser -ReregisterBroker
```

La réparation de base retire les contournements locaux WAM/ADAL bloquants dans `HKCU` et réenregistre le Broker s’il est absent ou présente un statut défectueux.

Le test réseau porte uniquement sur les métadonnées Entra : il ne valide ni le MFA, ni les licences, ni tous les points de terminaison Office.

</details>

**Après intervention :** vérifier la connexion dans Word, puis Outlook. Si l’erreur persiste, conserver le **code complet**, l’horodatage et l’identifiant de corrélation affichés par Office. La fin des opérations locales ne vaut pas validation de la connexion.

<a id="fonctionnalites"></a>

## ✨ Fonctionnalités

| Fonction | Description |
| --- | --- |
| **Diagnostic** | Relevé des versions et des paramètres utiles à la connexion Office, à WAM et à FSLogix. |
| **Interface Windows** | Choix de l’environnement : **Auto**, **RDS** ou **RDS + FSLogix**. |
| **Réparation de session** | Traitement dans le contexte de l’utilisateur affecté, sans arrêter les autres sessions. |
| **Réinitialisations ciblées** | Identités Office, comptes TokenBroker ou licences utilisateur, sur choix explicite. |
| **Déploiement utilisateur** | Réparation à la prochaine ouverture de session, une fois par campagne et par hôte. |
| **Activation partagée** | Configuration de Shared Computer Activation pour une installation Microsoft 365 Apps compatible. |
| **Simulation et restauration** | Prise en charge de `-WhatIf`, sauvegardes et journaux des opérations. |

<a id="contexte"></a>

## 📋 Prérequis et contexte d’exécution

| Opération | Contexte requis |
| --- | --- |
| Diagnostic et réparation utilisateur | Session de l’utilisateur affecté, avec Windows PowerShell 5.1 64 bits. |
| Installation ou retrait de la tâche | PowerShell **administrateur**. |
| Configuration de l’activation partagée | PowerShell **administrateur**, installation compatible et droits de licence vérifiés. |
| Restauration utilisateur | Même utilisateur et même hôte que la sauvegarde. |
| Restauration d’un manifeste `Host` | PowerShell **administrateur**, sur le même hôte. |

Pour la réparation utilisateur, utiliser le compte de la session concernée : **aucun autre compte administrateur, SYSTEM ou WinRM**. Fermer les applications Office avant l’intervention.

Les scripts ne sont pas signés. Si leur exécution est bloquée, les faire relire et signer selon les règles de votre organisation. Le lanceur respecte la politique d’exécution en place.

<a id="reparations"></a>

## 🔧 Réparations ciblées

Les réinitialisations sont **facultatives et indépendantes**. Choisir une option, tester, puis conserver le résultat avant d’en essayer une autre. Aucune purge n’est activée par défaut.

| Option | Cible | Conséquence à prévoir |
| --- | --- | --- |
| `-ResetOfficeIdentity` | Identités Office dans le registre utilisateur. | Reconnexion Office nécessaire. |
| `-ResetTokenBrokerAccounts` | Comptes mis en cache par TokenBroker. | Peut également déconnecter d’autres applications Microsoft. |
| `-ResetOfficeLicensing` | Licences Office de l’utilisateur. | Réactivation et licence éligible nécessaires. |

<details>
<summary><strong>Afficher les commandes PowerShell</strong></summary>

```powershell
# Réinitialiser les identités Office.
.\Repair-58TM1.ps1 -Mode RepairUser -ResetOfficeIdentity

# Réinitialiser les comptes TokenBroker.
.\Repair-58TM1.ps1 -Mode RepairUser -ResetTokenBrokerAccounts

# Réinitialiser les licences Office de cet utilisateur.
.\Repair-58TM1.ps1 -Mode RepairUser -ResetOfficeLicensing
```


</details>

Ajouter `-WhatIf` à une commande pour la simuler avant application.

> [!NOTE]
> Le script ne tue aucun processus et ne ferme aucune session. Il refuse de modifier le profil si une application Office tourne dans la session ; pour TokenBroker, Teams et OneDrive doivent aussi être fermés. Ne pas lancer la réparation simultanément sur plusieurs hôtes avec le même profil ou conteneur.

<a id="deploiement"></a>

## 🖥️ Déploiement pour tous les utilisateurs

Dans l’EXE, choisir **Déployer à l’ouverture de session**. Les commandes équivalentes et le fonctionnement de la campagne sont détaillés ci-dessous.

Après validation sur un utilisateur pilote, installer la tâche depuis **PowerShell administrateur** :

```powershell
# Simuler l’installation de la campagne.
.\Repair-58TM1.ps1 -Mode InstallLogonTask -Environment RDSFSLogix -DeploymentId Pilot-01 -WhatIf

# Installer la tâche.
.\Repair-58TM1.ps1 -Mode InstallLogonTask -Environment RDSFSLogix -DeploymentId Pilot-01

# Retirer la tâche pour désactiver les réparations futures.
.\Repair-58TM1.ps1 -Mode RemoveLogonTask
```

La tâche utilise le groupe `BUILTIN\Users`, avec un niveau de privilèges limité. Elle exécute la réparation **dans le contexte de chaque utilisateur, à sa prochaine nouvelle ouverture de session**.

- Les sessions déjà ouvertes ne sont pas réparées immédiatement. Une simple reconnexion à une session déconnectée ne suffit pas.
- Chaque campagne dispose d’un marqueur par **utilisateur, hôte et identifiant de déploiement**.
- Une erreur ou un refus ne produit pas de marqueur de réussite.
- Un marqueur confirme la fin des opérations locales ; la connexion Office reste à vérifier.
- Retirer la tâche conserve les sauvegardes et les changements déjà appliqués.

<details>
<summary><strong>Campagnes ciblées, permissions et déploiement en ferme</strong></summary>

Les options `-ResetOfficeIdentity`, `-ResetTokenBrokerAccounts` et `-ResetOfficeLicensing` sont également disponibles lors de l’installation de la tâche. Les choisir en fonction du diagnostic.

L’outil refuse d’écraser une tâche existante : retirer l’ancienne avant d’installer une nouvelle campagne.

Le moteur est installé dans `%ProgramData%\58tm1\Agent`, en lecture/exécution pour les utilisateurs et en écriture pour Administrateurs/SYSTEM.

Tester le déclenchement dans le mode de connexion réel, notamment **RemoteApp**, puis vérifier les résultats dans le Planificateur de tâches et les marqueurs du profil. Si Office démarre trop tôt, la réparation refuse la modification ; organiser l’ordre des scripts de connexion via les GPO.

Pour une ferme RDS, distribuer le kit avec vos outils GPO/RMM. Le script ne découvre et ne modifie pas automatiquement tous les serveurs.

</details>

<a id="activation"></a>

## 🔑 Activation partagée Office

Dans l’EXE, choisir **Configurer l’activation partagée**.

L’activation d’ordinateur partagé est distincte de la connexion WAM. Après audit et vérification des droits de licence, sur une édition Microsoft 365 Apps Click-to-Run compatible :

```powershell
# Exécuter en tant qu’administrateur.
.\Repair-58TM1.ps1 -Mode ConfigureHost -EnableSharedComputerActivation -WhatIf
.\Repair-58TM1.ps1 -Mode ConfigureHost -EnableSharedComputerActivation
```

Cette action définit uniquement `SharedComputerLicensing` à la chaîne `1` dans la configuration Click-to-Run, avec sauvegarde préalable.

Elle ne convertit pas Office perpétuel et n’attribue aucun droit de licence. Une stratégie contradictoire doit être corrigée dans sa source GPO/Intune. Prévoir la fermeture/réouverture d’Office et les étapes de maintenance applicables selon la documentation Microsoft.

<a id="restauration"></a>

## ↩️ Sauvegardes et restauration

Dans l’EXE, choisir **Restaurer : utilisateur** ou **Restaurer : hôte**, puis sélectionner le manifeste de l’intervention.

### Emplacements

| Élément | Emplacement |
| --- | --- |
| Rapports et manifestes utilisateur | `%LOCALAPPDATA%\58tm1\Runs` |
| Marqueurs de campagne | `%LOCALAPPDATA%\58tm1\Markers` |
| Sauvegardes des modifications de l’hôte | `%ProgramData%\58tm1\Runs` |
| Caches sauvegardés | À leur emplacement d’origine, avec le suffixe `.58tm1-backup-*`. |

Les caches sont **renommés sur place**, sans suppression récursive. Le registre est sauvegardé avant modification.

### Restaurer une intervention

Remplacer le chemin d’exemple par celui du `manifest.json` créé lors de l’intervention.

```powershell
# Simuler le retour arrière.
.\Repair-58TM1.ps1 -Mode Restore -ManifestPath 'C:\Users\...\AppData\Local\58tm1\Runs\...\manifest.json' -WhatIf

# Restaurer la sauvegarde.
.\Repair-58TM1.ps1 -Mode Restore -ManifestPath 'C:\Users\...\AppData\Local\58tm1\Runs\...\manifest.json'
```

Les caches régénérés sont conservés sous `.58tm1-before-restore-*`, et les clés actuelles sont sauvegardées avant restauration. Un fichier de progression permet de reprendre une restauration interrompue. Si une sauvegarde attendue manque, l’outil s’arrête.

L’enregistrement AppX est additif : il n’est pas désinstallé au retour arrière. Une restauration ne peut pas rétablir un jeton révoqué côté Microsoft ni garantir la validité d’un ancien cache. Utiliser uniquement les manifestes et sauvegardes de confiance créés par cet outil.

> [!CAUTION]
> Les sauvegardes peuvent contenir des données de compte et des caches d’authentification. Ne pas les partager publiquement. Elles occupent de l’espace dans le conteneur : les supprimer manuellement seulement après validation.

<a id="compatibilite"></a>

## 🧩 Compatibilité et limites

La cible technique est **Windows Server avec interface graphique, WAM/AppX et Windows PowerShell 5.1 64 bits**. Le mode `RDSFSLogix` exige des conteneurs activés et un service FSLogix démarré avant réparation.

La prise en charge de Microsoft 365 dépend de la version du serveur, du canal Office, de FSLogix et de leurs cycles de support. **Le kit n’est pas certifié pour toutes les versions de Windows Server.** Les composants absents doivent être diagnostiqués avant toute purge.

Le kit automatise les opérations locales décrites dans ce guide. Il ne saisit pas les mots de passe ou le MFA, n’attribue pas de licence et ne corrige pas les règles d’accès conditionnel. Il ne télécharge pas automatiquement de correctifs Windows/FSLogix, ne monte pas de VHDX, ne modifie pas `redirections.xml` et ne désactive aucune protection. Une jonction détectée dans un chemin à modifier provoque un arrêt pour analyse.

<a id="validation"></a>

## 🧪 Tests et compilation

| Vérification réalisée | Résultat |
| --- | --- |
| Tests du moteur PowerShell | **28 tests réussis** sous Linux. |
| Arguments, métadonnées et ressources de l’EXE | **50 vérifications réussies** sous Linux. |
| Compilation | **EXE Windows x64 compilé** avec références .NET Framework 4.8. |
| Exécution Windows/RDS, interface et UAC | **À valider sur Windows.** |

<details>
<summary><strong>Afficher les commandes de test et de compilation</strong></summary>

```powershell
# Tests hors production, également exécutables sous PowerShell 7 sur Linux.
pwsh -NoProfile -File .\tests\Test-Repair58TM1.ps1
```

Les tests du dépôt portent sur la syntaxe, les plans de réparation, le ciblage des sessions, les mutations simulées et les garde-fous.

**La validation fonctionnelle sur Windows/RDS reste nécessaire.** L’environnement de développement est Linux, sans hôte RDS, conteneur FSLogix ni tenant Microsoft 365. Aucun correctif de production n’y a été appliqué. L’EXE Windows x64 est compilé et ses ressources sont vérifiées ; l’affichage, l’UAC et les opérations Windows nécessitent un test sur Windows. Cette livraison n’est pas un installateur signé.

```powershell
# Recompiler l’EXE sous Windows.
.\desktop\Build-Desktop.ps1

# Vérifier les arguments, les ressources et les métadonnées de l’EXE.
pwsh -NoProfile -File .\tests\Test-Desktop.ps1
```

Pour vérifier un EXE placé à la racine du dossier plutôt que dans le répertoire de compilation :

```powershell
pwsh -NoProfile -File .\tests\Test-Desktop.ps1 -Executable .\58TM1.exe
```

</details>

Le workflow [Build Windows EXE](.github/workflows/build-windows.yml) fournit également une procédure de compilation et de tests sur un runner Windows GitHub Actions. Sa présence dans le dépôt ne signifie pas qu’une exécution a déjà réussi.

<a id="documentation"></a>

## 📚 Documentation

| Document | Contenu |
| --- | --- |
| [Analyse et sources](docs/RECHERCHE.md) | Pistes de diagnostic, références consultées et limites de la recherche. |
| [Validation RDS](docs/VALIDATION.md) | Procédure de test sur un hôte pilote et vérification de la persistance. |
| [Tests réalisés](docs/TESTS.md) | Périmètre des tests automatisés et limites de validation. |
| [Application EXE](docs/DESKTOP.md) | Exécution, élévation, ressources intégrées et compilation. |

---

<div align="center">

**Un périmètre choisi · Une action ciblée · Une sortie exploitable · Un retour arrière documenté**

</div>
