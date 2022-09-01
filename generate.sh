#!/usr/bin/env bash

# SPDX-FileCopyrightText: Maximilian Huber
#
# SPDX-License-Identifier: MIT

set -euo pipefail

orga="magma"
repo="magma"

[[ -f "./$repo.teams.csv" ]] || {
    >&2 echo GET "orgs/$orga/teams"
    while read -r row64; do
        row="$(echo "$row64" | base64 --decode)"
        name="$(echo "$row" | jq -r '.name')"
        url="$(echo "$row" | jq -r '.url')"
        >&2 echo GET "$url/members"
        while read -r user; do
            echo "$name,$user"
        done <<< "$(gh api -X GET "$url/members" --paginate | jq -r '.[].login')"
    done <<< "$(gh api -X GET "orgs/$orga/teams" --paginate | jq -r '.[] | @base64')"
} > "./$orga.teams.csv"

getTeamForUser() {
    local user="$1"
    {
        grep "^team-.*,$user\$" "./$repo.teams.csv" | sed 's/^team-//' | sed 's/,.*//' | head -1
    } || echo "UNKNOWN"
}

isUserApprover() {
    local user="$1"
    grep -q "^approvers-.*,$user\$" "./$repo.teams.csv" && echo 1 || echo 0
}

[[ -f "./$repo.pulls.json.gz" ]] || {
    >&2 echo GET "repos/$orga/$repo/pulls?state=all"
    [[ -f ""./.$repo.pulls.raw.json"" ]] || gh api -X GET "repos/$orga/$repo/pulls?state=all" --paginate > "./.$repo.pulls.raw.json"
    jq '.[]' < "./.$repo.pulls.raw.json" |
        gzip > "./$repo.pulls.json.gz"
}
[[ -f "./$repo.pulls.json.top_user" ]] || {
    >&2 echo "compute ./$repo.pulls.json.top_user"
    zcat "./$repo.pulls.json.gz" |
        jq -r '.user.login' |
        sort | uniq -c | sort -n > "./$repo.pulls.json.top_user"
}
[[ -f "./$repo.pulls.merged.json.gz" ]] || {
    >&2 echo "compute ./$repo.pulls.merged.json"
    zcat "./$repo.pulls.json.gz" | jq -r 'select(.merged_at != null)' |
        gzip > "./$repo.pulls.merged.json.gz"
}
[[ -f "./$repo.pulls.merged.json.top_user" ]] || {
    >&2 echo "compute ./$repo.pulls.merged.json.top_user"
    zcat "./$repo.pulls.merged.json.gz" |
        jq -r '.user.login' |
        sort | uniq -c | sort -n > "./$repo.pulls.merged.json.top_user"
}

[[ -f "./$repo.pulls.reviews.json.gz" ]] || {
    while read -r number; do
        if [[ -f "./$repo.pulls/$number.reviews.json" ]]; then
            cat "./$repo.pulls/$number.reviews.json"
        else
            mkdir -p "./$repo.pulls"
            >&2 echo GET "repos/$orga/$repo/pulls/$number/reviews"
            gh api -X GET "repos/$orga/$repo/pulls/$number/reviews" --paginate > "./$repo.pulls/.$number.reviews.raw.json"
            jq '.[]' < "./$repo.pulls/.$number.reviews.raw.json" | tee "./$repo.pulls/$number.reviews.json"
        fi
    done <<< "$(zcat "./$repo.pulls.json.gz" | jq -r '.number')"
} | gzip > "./$repo.pulls.reviews.json.gz"

[[ -f ./.prToUser.tsv ]] || zcat "$repo.pulls.json.gz" | jq -r '[.number,.user.login]|@tsv' > ./.prToUser.tsv

[[ -f "./$repo.pulls.reviews.json.relations.csv" ]] || {
    >&2 echo "compute ./$repo.pulls.reviews.json.relations.csv"
    while IFS=$'\t' read -r url user state; do
        number="$(basename "$url")"
        pr_user="$(rg "^${number}\t" ./.prToUser.tsv | sed 's/.*\t//')"
        echo "$user,$state,$pr_user"
    done <<< "$(zcat "./$repo.pulls.reviews.json.gz" | jq -r '[.pull_request_url,.user.login,.state]|@tsv' | rg -v "'COMMENTED'" | rg -v "'DISMISSED'")"
} | sort | uniq -c | sort -n | sed 's/^ *//' | sed 's/ /,/' > "./$repo.pulls.reviews.json.relations.csv"


getAllUsers() {
    local csv="$1"
    {
        while IFS=$',' read -r num user state pr_user; do
            echo "$user"
            echo "$pr_user"
        done < "$csv"
        cat "$orga.teams.csv" | sed 's/.*,//'
    } | sort -u
}

computeNodes() {
    local csv="$1"
    local prs_opened
    local prs_merged
    local team
    while read -r user; do
        if [[ -z "$user" ]]; then
            continue
        fi
        prs_opened="$(grep "$user\$" $repo.pulls.json.top_user | sed 's/^ *//' | sed 's/ .*//' || echo 0)"
        prs_merged="$(grep "$user\$" $repo.pulls.merged.json.top_user | sed 's/^ *//' | sed 's/ .*//' || echo 0)"
        team="$(getTeamForUser "$user")"
        cat <<EOF
         {
           "id": "$user",
           "team": "$team",
           "approver": $(isUserApprover "$user"),
           "prs_opened": $prs_opened,
           "prs_merged": $prs_merged,
           "label": "$user @ $team ($prs_merged merged of $prs_opened)"
         },
EOF
    done <<< "$(getAllUsers "$csv")"
}

computeLinks() {
    local csv="$1"
    while IFS=$',' read -r num user state pr_user; do
        if [[ "$state" == "APPROVED" || "$state" == "CHANGES_REQUESTED" ]]; then
            cat<<EOF
        {
          "source": "$user",
          "target": "$pr_user",
          "value": $num,
          "state": "$state"
EOF
            if [[ "$state" == "CHANGES_REQUESTED" ]]; then
                cat<<EOF
          , "pcolor": "rgba(255,0,0,0.2)"
EOF
            fi
            cat<<EOF
        },
EOF
        fi
    done < "$csv"
}

renderHtml() {
    local csv="$1"

    cat <<EOF
<!DOCTYPE html>
<!--
SPDX-FileCopyrightText: Maximilian Huber

SPDX-License-Identifier: MIT
-->
<head>
  <style> body { margin: 0; } </style>
  <script src="https://unpkg.com/force-graph"></script>
</head>

<body>
  <div id="graph"></div>

  <script>
    gData = {
      "nodes": [
$(computeNodes "$csv")
      ],
      "links": [
$(computeLinks "$csv")
      ]
    };

    let selfLoopLinks = {};
    let sameNodesLinks = {};
    const curvatureMinMax = 0.5;

    gData.nodes.forEach(node => {
      node.neighborsInbound = [];
      node.neighborsOutbound = [];
      node.links = [];
    });

    // 1. assign each link a nodePairId that combines their source and target independent of the links direction
    // 2. group links together that share the same two nodes or are self-loops
    gData.links.forEach(link => {
      link.nodePairId = link.source <= link.target ? (link.source + "_" + link.target) : (link.target + "_" + link.source);
      let map = link.source === link.target ? selfLoopLinks : sameNodesLinks;
      if (!map[link.nodePairId]) {
        map[link.nodePairId] = [];
      }
      map[link.nodePairId].push(link);

      // for highlighting
      const a = gData.nodes.find(node => node.id === link.source);
      const b = gData.nodes.find(node => node.id === link.target);
      a.neighborsOutbound.push(b);
      b.neighborsInbound.push(a);

      a.links.push(link);
      b.links.push(link);
    });

    // gData.nodes.forEach(node => {
      // node.label = node.label + " " + node.neighborsOutbound.length
    // });

    // Compute the curvature for self-loop links to avoid overlaps
    Object.keys(selfLoopLinks).forEach(id => {
      let links = selfLoopLinks[id];
      let lastIndex = links.length - 1;
      links[lastIndex].curvature = 1;
      let delta = (1 - curvatureMinMax) / lastIndex;
      for (let i = 0; i < lastIndex; i++) {
        links[i].curvature = curvatureMinMax + i * delta;
      }
    });

    // Compute the curvature for links sharing the same two nodes to avoid overlaps
    Object.keys(sameNodesLinks).filter(nodePairId => sameNodesLinks[nodePairId].length > 1).forEach(nodePairId => {
      let links = sameNodesLinks[nodePairId];
      let lastIndex = links.length - 1;
      let lastLink = links[lastIndex];
      lastLink.curvature = curvatureMinMax;
      let delta = 2 * curvatureMinMax / lastIndex;
      for (let i = 0; i < lastIndex; i++) {
        links[i].curvature = - curvatureMinMax + i * delta;
        if (lastLink.source !== links[i].source) {
          links[i].curvature *= -1; // flip it around, otherwise they overlap
        }
      }
    });

    const NODE_R = 4;

    const highlightNodesInbound = new Set();
    const highlightNodesOutbound = new Set();
    const highlightLinks = new Set();
    let hoverNode = null;
    const Graph = ForceGraph()
      (document.getElementById('graph'))
        .linkCurvature('curvature')
        .graphData(gData)
        .onNodeHover(node => {
            highlightNodesInbound.clear();
            highlightNodesOutbound.clear();
            highlightLinks.clear();
            if (node) {
                node.neighborsInbound.forEach(neighbor => highlightNodesInbound.add(neighbor));
                node.neighborsOutbound.forEach(neighbor => highlightNodesOutbound.add(neighbor));
                node.links.forEach(link => highlightLinks.add(link));
            }

            hoverNode = node || null;
        })
        .autoPauseRedraw(false) // keep redrawing after engine has stopped
        .nodeRelSize(NODE_R)
        .nodeVal(node => Math.log(node.neighborsOutbound.length + 1.5)/5)
        .nodeLabel('label')
        .nodeAutoColorBy('team')
        .linkDirectionalParticles("value")
        .linkDirectionalParticleSpeed(0.001)
        .linkDirectionalParticleColor(d => d.pcolor)
        .nodeCanvasObjectMode(node => 'before')
        .nodeCanvasObject((node, ctx) => {
            // add ring just for highlighted nodes
            ctx.beginPath();
            ctx.arc(node.x, node.y, NODE_R * 1.2, 0, 2 * Math.PI, false);
            if (node.approver === 1) {
                ctx.fillStyle = 'gray';
            } else {
                ctx.fillStyle = 'lightgray';
            }
            ctx.fill();
            if (highlightNodesOutbound.has(node)) {
                ctx.beginPath();
                ctx.arc(node.x, node.y, NODE_R * 1.2, 0, 1.33 * Math.PI, false);
                ctx.fillStyle = 'orange';
                ctx.fill();
            }
            if (highlightNodesInbound.has(node)) {
                ctx.beginPath();
                ctx.arc(node.x, node.y, NODE_R * 1.2, 0, 0.66 * Math.PI, false);
                ctx.fillStyle = 'red';
                ctx.fill();
            }
        })
        .linkDirectionalParticleWidth(link => highlightLinks.has(link) ? 4 : 2)
        .linkWidth(link => highlightLinks.has(link) ? 5 : 1)
        ;
  </script>
</body>
EOF
}

renderHtml "$repo.pulls.reviews.json.relations.csv" > review-network.html
