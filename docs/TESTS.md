# Verification realisee

Le 2 novembre 2026, sous Linux avec PowerShell 7.4.6 officiel (archive verifiee avec le fichier SHA-256 de la meme publication) : **28 tests reussis, 0 echec**.

Commande : `pwsh -NoProfile -File tests/Test-Repair58TM1.ps1`.

Les tests couvrent les plans sans purge par defaut, les options independantes, le ciblage des processus par session, l'arret avant mutation en cas de strategie bloquante ou manifeste absent, un vrai appel `-WhatIf`, l'ordre sauvegarde/renommage, le refus des liens/jonctions, les perimetres et identites de manifeste, le contenu autorise des sauvegardes `.reg`, les restrictions SCA et une restauration de cache sur des fichiers de test avec preservation du cache regenere.

Les commandes Windows sont simulees dans ces tests. Aucun test fonctionnel Office, RDS, AppX, ACL NTFS, tache planifiee, conteneur FSLogix ou MFA n'a ete execute. L'interface Windows Forms n'a pas ete affichee sur Linux ; sa syntaxe est analysee. La procedure de validation Windows reste dans `VALIDATION.md`.

## Application EXE 0.2.0

Compilation croisée C# réussie sous Linux, avec Roslyn fourni par PowerShell 7.4.6 et les références officielles .NET Framework 4.8 du package NuGet Microsoft `Microsoft.NETFramework.ReferenceAssemblies.net48` 1.0.3, téléchargé via HTTPS avec vérification TLS.

`pwsh -NoProfile -File tests/Test-Desktop.ps1` : **50 vérifications réussies**, couvrant les validations des requêtes, les arguments Windows avec espaces/guillemets, les modes d'élévation, le refus d'actions arbitraires, le format PE AMD64/Windows GUI, la version de l'assemblage et les neuf ressources intégrées vérifiées par SHA-256 et comparées aux sources.

Ces vérifications n'exécutent pas le binaire Windows. L'affichage, l'UAC, les ACL NTFS et la communication par canal nommé n'ont pas été exercés ici. La commande saute trois inspections PE propres à .NET moderne lorsqu'elle est lancée dans Windows PowerShell 5.1 ; elle réalise alors 47 vérifications si toutes passent. Aucun passage sur un runner Windows n'est revendiqué.
