# Application Windows 58TM1

Version `0.2.0-pilot`, destinée aux spécialistes informatique et infrastructure.

## Lancer

Ouvrir **58TM1.exe** normalement dans la session de l'utilisateur affecté. L'application est portable : le moteur et la documentation sont intégrés au binaire, sans téléchargement au lancement. Prérequis : Windows 64 bits avec interface graphique, **.NET Framework 4.8** et Windows PowerShell 5.1. Les composants Office/WAM/FSLogix requis dépendent de l'action choisie.

L'interface propose les environnements Auto, RDS et RDS + FSLogix, les réparations utilisateur, le déploiement à l'ouverture de session, l'activation partagée et la restauration utilisateur/hôte. Les sorties sont affichées dans la fenêtre et peuvent être exportées en `.log`. Il n'y a pas de collecte réseau automatique : le test HTTPS Entra est une option explicite.

Sélectionner **Simulation** ou la décocher pour appliquer. Le parcours s'adresse à des professionnels qui ont effectué leurs vérifications : aucune seconde boîte de confirmation n'est ajoutée à chaque exécution. Le moteur conserve ses contrôles de contexte, de sauvegarde et de périmètre. L'UAC apparaît seulement lorsqu'une action exige des droits administrateur.

## Élévation et fichiers locaux

Les opérations utilisateur restent dans le compte de la session. Une élévation avec un compte différent n'est pas une manière de réparer le profil d'un utilisateur : le moteur vérifie le compte de la session.

L'application extrait une copie vérifiée par SHA-256 des ressources intégrées dans un nouveau dossier :

- compte standard : `%LOCALAPPDATA%\58tm1\Desktop\0.2.0-<identifiant>` ;
- processus élevé : `%ProgramData%\58tm1\Desktop\0.2.0-<identifiant>`, protégé par ACL Administrateurs/SYSTEM.

Les sorties d'une opération élevée sont transmises à l'interface par un canal nommé local, sans écrire un journal privilégié à un chemin fourni par l'utilisateur. Le moteur élevé utilise sa copie protégée. Les dossiers d'extraction sont conservés pour permettre l'analyse et peuvent être supprimés après fermeture de l'application et fin des opérations ; cela ne supprime pas les sauvegardes sous `58tm1\Runs` ni le moteur d'une tâche installée sous `58tm1\Agent`.

La fenêtre ne peut pas être fermée pendant une opération. Le code de sortie et les erreurs sont affichés ; une opération locale terminée ne prouve pas que l'utilisateur a pu se reconnecter à Office.

## Politique d'exécution et signature

L'EXE et les scripts de cette livraison ne sont pas signés. L'application invoque le moteur intégré avec Windows PowerShell `-File`, sans `ExecutionPolicy Bypass`. Les stratégies de l'entreprise restent applicables. Si une signature de script est requise, signer `Repair-58TM1.ps1` avec votre certificat de code de confiance **avant de reconstruire l'EXE** ; signer ensuite le binaire pour la distribution. Une signature du seul EXE ne signe pas les scripts intégrés. SmartScreen peut avertir sur un éditeur inconnu.

## Recompiler

Sur Windows avec le compilateur .NET Framework disponible :

```powershell
.\desktop\Build-Desktop.ps1
```

La sortie est `dist\desktop\58TM1.exe`, avec son SHA-256. Le script n'utilise ni obfuscateur ni convertisseur PS2EXE. Le binaire est une application C# Windows Forms avec un moteur PowerShell intégré.

Pour une compilation croisée, utiliser PowerShell 7 avec Roslyn et les références officielles du package NuGet `Microsoft.NETFramework.ReferenceAssemblies.net48` version `1.0.3` :

```powershell
pwsh -NoProfile -File .\desktop\Build-Desktop.ps1 -ReferenceDirectory '<package>\build\.NETFramework\v4.8'
```

## État de validation

Compilation croisée et tests de logique possibles sous Linux. L'affichage Windows Forms, le déclenchement UAC, les ACL NTFS, les canaux nommés Windows, les tâches RDS et la connexion Office nécessitent un essai sur Windows. Cette version n'est pas présentée comme validée en production ou certifiée pour tous les Windows Server. Voir `VALIDATION.md` pour le pilote fonctionnel.
