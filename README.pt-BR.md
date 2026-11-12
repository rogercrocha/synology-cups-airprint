# synology-cups-airprint

[English](README.md)

> **Aviso sobre IA:** este projeto foi feito com a ajuda de IA (Claude, da
> Anthropic). A configuração foi testada pelo autor no próprio NAS Synology,
> impressora Brother, iPhone e Mac.

AirPrint para uma impressora de rede que não tem suporte a ele, servido pelo
CUPS num container Docker em um NAS Synology. iPhone, iPad e Mac encontram a
impressora sozinhos, e os controles de **cor / preto e branco** e de
**frente e verso** dos diálogos de impressão do iOS e do macOS funcionam de
verdade.

Montado e testado com uma Brother MFC-9460CDN (PCL6 / BR-Script3, sem IPP),
um NAS Synology com DSM 7 (aarch64), Debian 13 "trixie" (CUPS 2.4.10), iOS e
macOS. Deve funcionar com qualquer impressora que tenha driver
Foomatic/Ghostscript e em qualquer host Docker que permita rede do host.

## Por que existe

Fazer a fila *aparecer* no iPhone é fácil. Fazer ela se comportar exigiu
resolver quatro problemas que até estão documentados, mas quase nunca juntos:

1. **O controle de preto e branco é ignorado.** O CUPS anuncia
   `print-color-mode-supported = monochrome,color`, o controle aparece, e
   todo trabalho sai colorido mesmo assim. O CUPS 2.4 original só traduz
   `print-color-mode` para uma opção do PPD por meio de presets, e quando o
   PPD não tem `*APPrinterPreset`, ele cria sozinho o preset de escala de
   cinza apenas se o `ColorModel` tiver uma escolha chamada exatamente
   `Gray`. Os PPDs do Foomatic chamam de `Grayscale`, e nada é traduzido. O
   CUPS do Ubuntu tem um patch que esconde isso; o do Debian não. O
   entrypoint acrescenta presets explícitos ao PPD da fila.
2. **O iOS mostra "Reunindo informações da impressora" e a impressora some.**
   O iOS prefere IPPS. O CUPS cria o certificado autoassinado em
   `/etc/cups/ssl`, mas um volume montado em `/etc/cups` substitui a pasta
   da imagem, a subpasta não existe, e todo handshake TLS falha com
   `Unable to create server credentials`. O entrypoint cria a pasta.
3. **Um toque imprime a mesma página várias vezes.** Com
   `PreserveJobHistory No`, o CUPS apaga o trabalho assim que termina. O iOS
   então consulta o estado do trabalho, recebe "não encontrado", conclui que
   ele se perdeu e manda de novo. A configuração guarda o histórico por uma
   hora.
4. **O DSM não roda o avahi**, então o container roda o seu próprio dbus e
   avahi, com a rede do host.

## Vai funcionar com a minha impressora?

Provavelmente, se tudo isto for verdade:

- **O NAS alcança a impressora** pela rede: socket (porta 9100), LPD
  (`lpd://`) ou IPP. Impressoras USB não estão cobertas aqui.
- **Existe driver para ela na imagem.** A imagem traz os drivers genéricos
  do CUPS e o `foomatic-db` (os drivers do Ghostscript, como `pxlcolor`,
  `pxlmono` e `ljet4`). Outras famílias precisam de um pacote Debian a mais
  na linha `apt-get install` do `Dockerfile`, e depois um novo build:
  `hplip` para HP, `printer-driver-brlaser` para muitas lasers Brother,
  `printer-driver-splix` para Samsung e Xerox, `printer-driver-gutenprint`
  para muitas jato de tinta. Liste o que está disponível com
  `sudo docker exec cups-airprint lpinfo -m`.
- **O driver roda no processador do seu NAS.** Drivers binários de
  fabricante feitos só para x86 não rodam nos modelos ARM.

Sobre o controle de preto e branco: a correção deste repositório vale para
PPDs cujo `ColorModel` tem a escolha `Grayscale` (Foomatic). Nos outros PPDs,
o CUPS traduz o controle sozinho quando a escolha de cinza é uma que ele
conhece (`ColorModel=Gray`, o `grayscale` da HP, o `BRMonoColor=Mono` da
Brother e mais alguns); se não for, o controle pode aparecer e não fazer
nada.

Se a sua impressora já tem AirPrint ou IPP Everywhere, você não precisa
disto.

Até agora foi testado com uma impressora, a Brother MFC-9460CDN. Relatos com
outros modelos, funcionando ou não, são bem-vindos como issues.

## Requisitos

- NAS Synology com DSM 7 e **Container Manager** (ou qualquer host Linux com
  Docker e Compose).
- Acesso SSH ao NAS com uma conta de administrador.
- A impressora na rede com IP fixo (uma reserva de DHCP basta) e impressão
  por socket na porta 9100.
- O servidor de impressão do próprio DSM desligado (a porta 631 precisa
  estar livre).

## Instalação

1. Baixe este repositório para a sua pasta pessoal no NAS. O DSM não tem
   `git` a menos que você instale o pacote Git Server, mas o `curl` funciona:

   ```bash
   cd ~ && curl -L https://github.com/rogercrocha/synology-cups-airprint/archive/refs/heads/main.tar.gz | tar xz \
     && mv synology-cups-airprint-main synology-cups-airprint
   ```
2. Descubra o driver da sua impressora. Depois do primeiro build, liste com
   `sudo docker exec cups-airprint lpinfo -m | grep -i <modelo>`; um modelo
   próximo da mesma família costuma servir.
3. Rode o script uma vez. Ele cria o `.env` a partir do `.env.example` e para:

   ```bash
   cd ~/synology-cups-airprint && sudo bash deploy.sh
   ```

4. Edite `/volume1/docker/synology-cups-airprint/.env` (no mínimo
   `PRINTER_URI`, `PRINTER_PPD` e `QUEUE_NAME`) e rode o script de novo. Ele
   constrói a imagem, sobe o container, cria a fila e mostra o que o iPhone
   vai enxergar. Se você deixou `change-me`, uma senha aleatória para a
   interface web é gravada no `.env`.

No iPhone ou no Mac, escolha a entrada cujo nome termina em
**"@ <nome do seu NAS>"**. Se a impressora também se anuncia sozinha, a
entrada sem esse sufixo é ela, não este servidor.

## Configurações (`.env`)

| Variável | Exemplo | Significado |
|---|---|---|
| `PRINTER_URI` | `socket://192.168.1.50:9100` | Como o CUPS chega à impressora |
| `PRINTER_PPD` | `foomatic:Brother-HL-4050CDN-pxlcolor.ppd` | Driver, do `lpinfo -m` |
| `QUEUE_NAME` | `Brother_MFC-9460CDN` | Nome da fila, sem espaços |
| `QUEUE_DESC` | `Brother MFC-9460CDN` | Nome exibido nos aparelhos |
| `PRINTER_LOCATION` | `Casa` | Texto de localização |
| `PAGE_SIZE` | `A4` | Papel padrão |
| `COLOR_DEFAULT` | `color` | Padrão para trabalhos que não dizem (o macOS abre o diálogo com ele) |
| `CUPS_USER` / `CUPS_PASSWORD` | `print` | Login de `http://<IP-do-NAS>:631` |

As configurações que criam a fila só valem quando ela ainda não existe. Para
recomeçar, pare o container e tire a pasta `config` do lugar.

## Testando a tradução de cor

```bash
sudo docker exec cups-airprint cupsctl LogLevel=debug2
sudo docker exec cups-airprint sh -c "printf '%%!PS\n1 0 0 setrgbcolor 72 72 200 200 rectfill showpage\n' | lp -d <QUEUE_NAME> -o print-color-mode=monochrome"
sudo docker exec cups-airprint sh -c 'grep -aoE "Adding preset option [^ ]+|sDEVICE=[a-z]+" /var/log/cups/error_log'
sudo docker exec cups-airprint cupsctl LogLevel=warn
```

No papel deve sair um quadrado cinza, e no log
`Adding preset option ColorModel=Grayscale` e um device monocromático do
Ghostscript (nesta Brother, `pxlmono`). Use uma página leve como esta nos
testes: a página de teste colorida do CUPS a 600 dpi foi pesada o bastante
para fazer esta impressora reiniciar.

## Solução de problemas

- **A impressora sumiu dos aparelhos depois de mudar a fila com `lpadmin`.**
  O CUPS registra o serviço Bonjour de novo, e o avahi dentro do container
  às vezes deixa de responder às buscas por ele, embora o serviço ainda
  resolva pelo nome. `sudo docker restart cups-airprint` resolve.
- **Preto e branco continua saindo colorido.** Confira se o PPD da fila tem
  presets: `sudo docker exec cups-airprint grep -c APPrinterPreset /etc/cups/ppd/<QUEUE_NAME>.ppd`.
  Os presets só são acrescentados quando o `ColorModel` tem a escolha
  `Grayscale`; outros drivers podem usar outros nomes.
- **"Reunindo informações da impressora" no iOS.** Procure
  `Unable to create server credentials` em `/var/log/cups/error_log` e
  confira se `/etc/cups/ssl` existe dentro do container.
- **O mesmo trabalho sai várias vezes.** Verifique se `PreserveJobHistory`
  não está como `No` em `/etc/cups/cupsd.conf`.

## Limitações

- O CUPS 3 abandona os PPDs. Esta montagem depende deles; o substituto de
  longo prazo é um Printer Application como o `ghostscript-printer-app`,
  que hoje só é publicado para arm64 como snap.
- O `/admin` é acessível por toda a rede local, protegido pela senha do
  `.env`. Não redirecione a porta 631 para a internet.

## Licença

[MIT](LICENSE)
