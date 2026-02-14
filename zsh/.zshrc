# Path to your oh-my-zsh installation.
# Reevaluate the prompt string each time it's displaying a prompt
setopt prompt_subst
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
autoload bashcompinit && bashcompinit
autoload -Uz compinit
compinit
source <(kubectl completion zsh)
complete -C '/usr/local/bin/aws_completer' aws

source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh
bindkey '^w' autosuggest-execute
bindkey '^e' autosuggest-accept
bindkey '^u' autosuggest-toggle
bindkey '^L' vi-forward-word
bindkey '^k' up-line-or-search
bindkey '^j' down-line-or-search

eval "$(starship init zsh)"
export STARSHIP_CONFIG=~/.config/starship/starship.toml

# You may need to manually set your language environment
export LANG=en_US.UTF-8

export EDITOR=/opt/homebrew/bin/nvim

alias la=tree
alias cat=bat

# Git
alias gc="git commit -m"
alias gca="git commit -a -m"
alias gp="git push origin HEAD"
alias gpu="git pull origin"
alias gst="git status"
alias glog="git log --graph --topo-order --pretty='%w(100,0,6)%C(yellow)%h%C(bold)%C(black)%d %C(cyan)%ar %C(green)%an%n%C(bold)%C(white)%s %N' --abbrev-commit"
alias gdiff="git diff"
alias gco="git checkout"
alias gb='git branch'
alias gba='git branch -a'
alias gadd='git add'
alias ga='git add -p'
alias gcoall='git checkout -- .'
alias gr='git remote'
alias gre='git reset'
alias gsw="git switch"
alias gswc="git switch -c"
alias gaa="git add -A"
alias gcam="git commit --amend --no-edit"
alias gstash="git stash"
alias gstashp="git stash pop"
alias gstashl="git stash list"
alias grecent='git for-each-ref --sort=-committerdate --count=10 --format="%(refname:short) %(committerdate:relative)" refs/heads/'
alias gbclean='git branch --merged | grep -v "^\*\|main\|master\|develop" | xargs -r git branch -d'

# Docker
alias dco="docker compose"
alias dps="docker ps"
alias dpa="docker ps -a"
alias dl="docker ps -l -q"
alias dx="docker exec -it"
alias dcup="docker compose up -d"
alias dcdn="docker compose down"
alias dcl="docker compose logs -f"
alias dcb="docker compose build"
alias dcr="docker compose restart"

# Terraform
alias tf="terraform"
alias tfi="terraform init"
alias tfp="terraform plan"
alias tfa="terraform apply"
alias tfd="terraform destroy"
alias tff="terraform fmt -recursive"
alias tfo="terraform output"

# Helm
alias h="helm"
alias hu="helm upgrade --install"
alias hls="helm list -A"
alias hs="helm status"
alias ht="helm template"
alias hdel="helm uninstall"

# Flux CD
alias fxr="flux reconcile source git flux-system"
alias fxrk="flux reconcile kustomization"
alias fxgs="flux get sources git"
alias fxgk="flux get kustomizations"
alias fxgh="flux get helmreleases -A"

# GitLab CLI
alias glmr="glab mr create --fill"
alias glmrl="glab mr list"
alias glmrv="glab mr view --web"
alias glci="glab ci view"

# Dirs
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."
alias ......="cd ../../../../.."

# GO
export GOPATH="$HOME/go"

# VIM
alias v="nvim"

# Nmap
alias nm="nmap -sC -sV -oN nmap"

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.vimpkg/bin:${GOPATH}/bin:$HOME/.cargo/bin


export PATH="$HOME/.local/bin:$PATH"
alias cl='clear'

# K8S
export KUBECONFIG=~/.kube/config
alias k="kubectl"
alias ka="kubectl apply -f"
alias kg="kubectl get"
alias kd="kubectl describe"
alias kdel="kubectl delete"
alias kgpo="kubectl get pod"
alias kgd="kubectl get deployments"
alias kc="kubectx"
alias kns="kubens"
alias kl="kubectl logs -f"
alias ke="kubectl exec -it"
alias kcns='kubectl config set-context --current --namespace'
alias kgn="kubectl get nodes"
alias kgs="kubectl get svc"
alias kgi="kubectl get ingress"
alias kga="kubectl get all"
alias kgaa="kubectl get all -A"
alias kpf="kubectl port-forward"
alias ktn="kubectl top nodes"
alias ktp="kubectl top pods"
alias krun="kubectl run -it --rm debug --image=busybox --restart=Never -- sh"

podname() { kubectl get pods --no-headers -o custom-columns=':metadata.name' | fzf; }
kexf() { ke "$(podname)" -- "${1:-sh}"; }
klf() { kl "$(podname)"; }

# HTTP requests with xh!
alias http="xh"

# VI Mode!!!
bindkey jj vi-cmd-mode

# Eza
alias l="eza -l --icons --git -a"
alias lt="eza --tree --level=2 --long --icons --git"
alias ltree="eza --tree --level=2  --icons --git"

# Suffix aliases (type filename to open with tool)
alias -s md=glow

# SEC STUFF
alias gobust='gobuster dir --wordlist ~/security/wordlists/diccnoext.txt --wildcard --url'
alias dirsearch='python dirsearch.py -w db/dicc.txt -b -u'
alias massdns='~/hacking/tools/massdns/bin/massdns -r ~/hacking/tools/massdns/lists/resolvers.txt -t A -o S bf-targets.txt -w livehosts.txt -s 4000'
alias server='python -m http.server 4445'
alias tunnel='ngrok http 4445'
alias fuzz='ffuf -w ~/hacking/SecLists/content_discovery_all.txt -mc all -u'
alias gf='~/go/src/github.com/tomnomnom/gf/gf'

### FZF ###
export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow'
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

export PATH=/opt/homebrew/bin:$PATH

alias mat='osascript -e "tell application \"System Events\" to key code 126 using {command down}" && tmux neww "cmatrix"'

# Nix!
export NIX_CONF_DIR=$HOME/.config/nix
export PATH=/run/current-system/sw/bin:$PATH

function ranger {
	local IFS=$'\t\n'
	local tempfile="$(mktemp -t tmp.XXXXXX)"
	local ranger_cmd=(
		command
		ranger
		--cmd="map Q chain shell echo %d > "$tempfile"; quitall"
	)

	${ranger_cmd[@]} "$@"
	if [[ -f "$tempfile" ]] && [[ "$(cat -- "$tempfile")" != "$(echo -n `pwd`)" ]]; then
		cd -- "$(cat "$tempfile")" || return
	fi
	command rm -f -- "$tempfile" 2>/dev/null
}
alias rr='ranger'

# navigation
cx() { cd "$@" && l; }
fcd() { cd "$(fd --type d --hidden --follow | fzf)" && l; }
f() { echo "$(fd --type f --hidden --follow | fzf)" | pbcopy }
fv() { nvim "$(fd --type f --hidden --follow | fzf)" }

# Quick config editing + reload
alias ez="nvim ~/.config/zsh/.zshrc"
alias et="nvim ~/.config/tmux/tmux.conf"
alias en="nvim ~/.config/nvim/"
alias edot="cd ~/.code/dotfiles && l"
alias sz="source ~/.config/zsh/.zshrc"

# Port/process management
port() { lsof -i :"$1" | grep LISTEN; }
killport() { lsof -ti :"$1" | xargs kill -9; }

# Network quick checks
alias myip="curl -s ifconfig.me"
alias localip="ipconfig getifaddr en0"
alias ports="lsof -iTCP -sTCP:LISTEN -n -P"

# YAML helpers (yq)
alias yj="yq -o json"
alias jy="yq -p json"

 # Nix
 if [ -e '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh' ]; then
	 . '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
 fi
 # End Nix

export XDG_CONFIG_HOME="$HOME/.config"

eval "$(zoxide init zsh)"
eval "$(atuin init zsh)"
eval "$(direnv hook zsh)"


# k8s-lab cluster (bare metal Talos)
export K8SLAB="$HOME/.code/scratch/k8s-bare-metal-lab"
export KUBECONFIG_K8SLAB="$K8SLAB/talos-new/kubeconfig"
export TALOSCONFIG_K8SLAB="$K8SLAB/talos-new/talosconfig"
export KUBECONFIG_K8SLAB_OIDC="$K8SLAB/kubernetes/platform/auth/kubeconfig-oidc.yaml"
alias klab='KUBECONFIG=$KUBECONFIG_K8SLAB kubectl'       # admin (cert)
alias ko='KUBECONFIG=$KUBECONFIG_K8SLAB_OIDC kubectl'    # GitLab OIDC
alias k9s-lab='KUBECONFIG=$KUBECONFIG_K8SLAB k9s'
alias k9s-oidc='KUBECONFIG=$KUBECONFIG_K8SLAB_OIDC k9s'
alias tc='talosctl --talosconfig=$TALOSCONFIG_K8SLAB'

eval "$(mise activate zsh)"

# Work-specific config (not tracked in git)
[ -f "$HOME/.config/zsh/work.zsh" ] && source "$HOME/.config/zsh/work.zsh"
