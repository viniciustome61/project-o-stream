package add_lan_candidates

import (
	"fmt"
	"slices"
	"is_lan_ip"
)

func add_lan_candidates(candidates []string, ip *string) []string {
	if is_lan_ip(*ip) && !slices.Contains(candidates, *ip){
		if *ip != nil{
			candidates = append(candidates, *ip)
		}
	}
	return candidates
}

//Projeto da LP(Premissas, Usuário, Dominio)

