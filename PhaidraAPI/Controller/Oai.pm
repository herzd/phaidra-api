package PhaidraAPI::Controller::Oai;

# based on https://github.com/LibreCat/Dancer-Plugin-Catmandu-OAI

use strict;
use warnings;
use v5.10;
use base 'Mojolicious::Controller';
use Switch;
use Data::MessagePack;
use MIME::Base64 qw(encode_base64url decode_base64url);
use DateTime;
use DateTime::Format::ISO8601;
use DateTime::Format::Strptime;
use Clone qw(clone);
use Mojo::JSON qw(encode_json decode_json);
use Mojo::ByteStream qw(b);

my $DEFAULT_LIMIT = 100;

# pretend you don't see this
my %iso6393ToBCP = reverse %{$PhaidraAPI::Model::Languages::iso639map};

my $resourceTypesToDownload = {
  'http://purl.org/coar/resource_type/c_18cc' => 1, # sound
  'http://purl.org/coar/resource_type/c_18cf' => 1, # text
  'http://purl.org/coar/resource_type/c_6501' => 1, # journal article
  'http://purl.org/coar/resource_type/c_c513' => 1, # image
  'http://purl.org/coar/resource_type/c_12ce' => 1 # video
};

my $relations = {
  'references' => 'References',
  'isbacksideof' => 'Continues',
  'hassuccessor' => 'IsPreviousVersionOf',
  'isalternativeformatof' => 'IsVariantFormOf',
  'isalternativeversionof' => 'IsVersionOf',
  'ispartof' => 'IsPartOf'
}

my $openaireContributorType = {
  # ContactPerson
  # DataCollector
  # DataCurator
  dtm => "DataManager",
  dst => "Distributor",
  edt => "Editor",
  his => "HostingInstitution",
  pro => "Producer",
  pdr => "ProjectLeader", # Project director
  # ProjectManager
  # ProjectMember
  # RegistrationAgency
  # RegistrationAuthority
  # RelatedPerson
  res => "Researcher",
  # ResearchGroup
  # RightsHolder
  spn => "Sponsor"
  # Supervisor
  # WorkPackageLeader
  # Other < all unmapped contributor roles
};

my $VERBS = {
  GetRecord => {
    valid    => {metadataPrefix => 1, identifier => 1},
    required => [qw(metadataPrefix identifier)],
  },
  Identify        => {valid => {}, required => []},
  ListIdentifiers => {
    valid => {
      metadataPrefix  => 1,
      from            => 1,
      until           => 1,
      set             => 1,
      resumptionToken => 1
    },
    required => [qw(metadataPrefix)],
  },
  ListMetadataFormats =>
    {valid => {identifier => 1, resumptionToken => 1}, required => []},
  ListRecords => {
    valid => {
      metadataPrefix  => 1,
      from            => 1,
      until           => 1,
      set             => 1,
      resumptionToken => 1
    },
    required => [qw(metadataPrefix)],
  },
  ListSets => {valid => {resumptionToken => 1}, required => []},
};

sub _deserialize {
  my ($self, $data) = @_;
  my $mp = Data::MessagePack->new->utf8;
  return $mp->unpack(decode_base64url($data));
}

sub _serialize {
  my ($self, $data) = @_;
  my $mp = Data::MessagePack->new->utf8;
  return encode_base64url($mp->pack($data));
}

sub _get_roles_uwm {
  my ($self, $str) = @_;

  my @roles;

  my $arr = decode_json(b($str)->encode('UTF-8'));
  my @contrib = sort { $a->{data_order} <=> $b->{data_order} } @{$arr};
  for my $con (@contrib) {
    my @entities = sort { $a->{data_order} <=> $b->{data_order} } @{$con->{entities}};
    for my $e (@entities) {
      my %role;
      my @ids;
      my @affiliations;
      my $roleCode = $con->{role};
      next if $roleCode eq 'uploader';
      switch ($roleCode) {
        case 'aut' {
          $role{dcRole} = 'creator';
        }
        case 'pbl' {
          $role{dcRole} = 'publisher';
        }
        default {
          $role{dcRole} = 'contributor';
          $role{contributorType} = exists($openaireContributorType->{$roleCode}) ? $openaireContributorType->{$roleCode} : 'Other';
        }
      }

      if ($e->{orcid}) {
        push @ids, {
          nameIdentifier => $e->{orcid},
          nameIdentifierScheme => 'ORCID',
          schemeURI => 'https://orcid.org/'
        }
      }
      if ($e->{gnd}) {
        push @ids, {
          nameIdentifier => $e->{gnd},
          nameIdentifierScheme => 'GND',
          schemeURI => 'https://d-nb.info/gnd/'
        }
      }
      if ($e->{isni}) {
        push @ids, {
          nameIdentifier => $e->{isni},
          nameIdentifierScheme => 'ISNI',
          schemeURI => 'http://isni.org/isni/'
        }
      }
      if ($e->{viaf}) {
        push @ids, {
          nameIdentifier => $e->{viaf},
          nameIdentifierScheme => 'VIAF',
          schemeURI => 'https://viaf.org/viaf/'
        }
      }
      if ($e->{wdq}) {
        push @ids, {
          nameIdentifier => $e->{wdq},
          nameIdentifierScheme => 'Wikidata',
          schemeURI => 'https://www.wikidata.org/wiki/'
        }
      }
      if ($e->{lcnaf}) {
        push @ids, {
          nameIdentifier => $e->{lcnaf},
          nameIdentifierScheme => 'LCNAF',
          schemeURI => 'https://id.loc.gov/authorities/names/'
        }
      }

      if ($e->{firstname} || $e->{lastname}) {
        $role{nameType} = 'Personal';
        $role{name} = $e->{lastname};
        $role{name} += ', '. $e->{firstname} if $e->{firstname};
        $role{givenName} = $e->{firstname};
        $role{familyName} = $e->{lastname};
        push @affiliations, $e->{institution};
        $role{affiliations} = \@affiliations;
      } else {
        if ($e->{institution}) {
          $role{nameType} = 'Organizational';
          $role{name} = $e->{institution};
        }
      }
      $role{nameIdentifiers} = \@ids;
    }
  }

  return \@roles;
}

sub _get_roles {
  my ($self, $str) = @_;

  my @roles;

  my $arr = decode_json(b($str)->encode('UTF-8'));
  for my $hash (@{$arr}) {
    for my $rolePredicate (keys %{$hash}) {
      for my $e (@{$hash->{$rolePredicate}}) {
        my %role;
        my $firstname;
        my $lastname;
        my @affiliations;
        my $name;
        my @ids;
        my $roleCode = $rolePredicate;
        $roleCode =~ s/^role://g;
        next if $roleCode eq 'uploader';
        switch ($roleCode) {
          case 'aut' {
            $role{dcRole} = 'creator';
          }
          case 'pbl' {
            $role{dcRole} = 'publisher';
          }
          default {
            $role{dcRole} = 'contributor';
            $role{contributorType} = exists($openaireContributorType->{$roleCode}) ? $openaireContributorType->{$roleCode} : 'Other';
          }
        }
        for my $prop (keys %{$e}){
          if($prop eq '@type'){
            if ($e->{$prop} eq 'schema:Person') {
              $role{nameType} = 'Personal'
            }
            if ($e->{$prop} eq 'schema:Organization') {
              $role{nameType} = 'Organizational'
            }
          }
          if($prop eq 'schema:givenName'){
            for my $v (@{$e->{$prop}}){
              $firstname = $v->{'@value'}
            }
          }
          if($prop eq 'schema:familyName'){
            for my $v (@{$e->{$prop}}){
              $lastname = $v->{'@value'}
            }
          }
          if($prop eq 'schema:name'){
            for my $v (@{$e->{$prop}}){
              $name = $v->{'@value'}
            }
          }
          if($prop eq 'skos:exactMatch'){
            for my $id (@{$e->{$prop}}){
              if ($id->{'@type'} eq 'ids:orcid') {
                push @ids, {
                  nameIdentifier => $id->{'@value'},
                  nameIdentifierScheme => 'ORCID',
                  schemeURI => 'https://orcid.org/'
                }
              }
              if ($id->{'@type'} eq 'ids:gnd') {
                push @ids, {
                  nameIdentifier => $id->{'@value'},
                  nameIdentifierScheme => 'GND',
                  schemeURI => 'https://d-nb.info/gnd/'
                }
              }
              if ($id->{'@type'} eq 'ids:isni') {
                push @ids, {
                  nameIdentifier => $id->{'@value'},
                  nameIdentifierScheme => 'ISNI',
                  schemeURI => 'http://isni.org/isni/'
                }
              }
              if ($id->{'@type'} eq 'ids:viaf') {
                push @ids, {
                  nameIdentifier => $id->{'@value'},
                  nameIdentifierScheme => 'VIAF',
                  schemeURI => 'https://viaf.org/viaf/'
                }
              }
              if ($id->{'@type'} eq 'ids:wikidata') {
                push @ids, {
                  nameIdentifier => $id->{'@value'},
                  nameIdentifierScheme => 'Wikidata',
                  schemeURI => 'https://www.wikidata.org/wiki/'
                }
              }
              if ($id->{'@type'} eq 'ids:lcnaf') {
                push @ids, {
                  nameIdentifier => $id->{'@value'},
                  nameIdentifierScheme => 'LCNAF',
                  schemeURI => 'https://id.loc.gov/authorities/names/'
                }
              }
            }
          }

          if($prop eq 'schema:affiliation'){
            my %affs;
            my $addInstitutionName = 0;
            for my $affProp (@{$e->{'schema:affiliation'}}){
              if ($affProp eq 'skos:exactMatch') {
                for my $affId (@{$e->{'schema:affiliation'}->{'skos:exactMatch'}}) {
                  if (rindex($affId, '"https://pid.phaidra.org/', 0) == 0) {
                    $addInstitutionName = 1;
                  }
                }
              }
              if ($affProp eq 'schema:name') {
                for my $affName (@{$e->{'schema:affiliation'}->{'schema:name'}}) {
                  if (exists($affName->{'@language'})) {
                    if ($affName->{'@language'} ne '') {
                      $affs{$affName->{'@language'}} = $affName->{'@value'};
                    } else {
                      $affs{'nolang'} = $affName->{'@value'};
                    }
                  } else {
                    $affs{'nolang'} = $affName->{'@value'};
                  }
                }
              }
            }

            # https://openaire-guidelines-for-literature-repository-managers.readthedocs.io/en/v4.0.0/field_publisher.html
            # I think this should apply to affiliations of creators and contributors too:
            # "With university publications place the name of the faculty and/or research group or research school 
            # after the name of the university. In the case of organizations where there is clearly a hierarchy present,
            # list the parts of the hierarchy from largest to smallest, separated by full stops."

            # prefer version without language
            if ($affs{'nolang'}) {
              push @affiliations, $affs{'nolang'};
            } else {
              # if not found, prefer english
              if ($affs{'eng'}) {
                my $affiliation = $affs{'eng'};
                if ($addInstitutionName) {
                  my $institutionName = $self->app->directory->get_org_name($self, 'eng');
                  if ($institutionName) {
                    if ((index($affiliation, $institutionName) == -1)) {
                      $affiliation = "$institutionName. $affiliation";
                    }
                  }
                }
                push @affiliations, $affiliation;
              } else {
                # if not found just pop whatever
                my $affiliation;
                for my $affLang (keys %affs) {
                  $affiliation = $affs{$affLang};
                  if ($addInstitutionName) {
                    my $institutionName = $self->app->directory->get_org_name($self, $affLang);
                    if ($institutionName) {
                      if ((index($affiliation, $institutionName) == -1)) {
                        $affiliation = "$institutionName. $affiliation";
                      }
                    }
                  }
                  last;
                }
                push @affiliations, $affiliation;
              }
            }
          }
        }
        if ($role{nameType} eq 'Personal') {
          if ($name) {
            $role{name} = $name;
          } else {
            $role{name} = $lastname;
            $role{name} += ', '. $firstname if $firstname;
          }
          $role{givenName} = $firstname;
          $role{familyName} = $lastname;
          $role{affiliations} = \@affiliations;
        } else {
          $role{name} = $name;
        }
        $role{nameIdentifiers} = \@ids;
      }
    }
  }

  return \@roles;
}

sub _get_funding_references {
  my ($self, $str) = @_;

  my @fundingReferences;

  my $arr = decode_json(b($str)->encode('UTF-8'));

  for my $obj (@$arr) {
    my $funderName;
    my $awardTitle;
    my $awardNumber;
    if ($obj->{'@type'} eq 'foaf:Project') {
      if (exists($obj->{'skos:prefLabel'})) {
        for my $l (@{$obj->{'skos:prefLabel'}}) {
          $awardTitle = $l->{'@value'};
          last;
        }
      }
      if (exists($obj->{'skos:exactMatch'})) {
        for my $id (@{$obj->{'skos:exactMatch'}}) {
          $awardNumber = $id;
          last;
        }
      }
      if (exists($obj->{'frapo:hasFundingAgency'})) {
        for my $fun (@{$obj->{'frapo:hasFundingAgency'}}) {
          if (exists($fun->{'skos:prefLabel'})) {
            for my $l (@{$fun->{'skos:prefLabel'}}) {
              $funderName = $l->{'@value'};
              last;
            }
          }
        }
      }
    }
    if ($obj->{'@type'} eq 'frapo:FundingAgency') {
      if (exists($obj->{'skos:prefLabel'})) {
        for my $l (@{$obj->{'skos:prefLabel'}}) {
          $funderName = $l->{'@value'};
          last;
        }
      }
    }
    push @fundingReferences, {
      funderName => $funderName,
      awardTitle => $awardTitle,
      awardNumber => $awardNumber
    }
  }
  return \@fundingReferences;
}

sub _get_metadata_dc {
  my ($self, $rec) = @_;

  my @metadata;
  for my $k (keys %{$rec}) {
    if ($k =~ m/^dc_([a-z]+)_?([a-z]+)?$/) {
      my %field;
      $field{name} = $1;
      $field{values} = $rec->{$k};
      $field{lang} = $2 if $2;
      push @metadata, \%field;
    }
  }
  return \@metadata;
}

sub _rolesToNodes {
  my ($self, $type, $roles) = @_;

  my @roleNodes;
  for my $role (@$roles) {
    my @childNodes;
    my %nameNode;
    $nameNode{name} = $type eq 'creator' ? 'datacite:creatorName' : 'datacite:contributorName';
    $nameNode{value} = $role->{name};
    if ($role->{nameType}) {
      $nameNode{attributes} = [
        {
          name => 'nameType',
          value => $role->{nameType}
        }
      ]
    }
    push @childNodes, \%nameNode;
    for my $id (@{$role->{nameIdentifiers}}) {
      push @childNodes, {
        name => 'datacite:nameIdentifier',
        value => $id->{nameIdentifier},
        attributes => [
          {
            name => 'nameIdentifierScheme',
            value => $id->{nameIdentifierScheme}
          },
          {
            name => 'schemeURI',
            value => $id->{schemeURI}
          }
        ]
      }
    }
    for my $aff (@{$role->{affiliations}}) {
      push @childNodes, {
        name => 'datacite:affiliation',
        value => $aff
      }
    }
    push @roleNodes, {
      name => $type eq 'creator' ? 'datacite:creator' : 'datacite:contributor',
      children => \@childNodes
    }
  }
  return \@roleNodes;
}

sub _map_iso3_to_bcp {
  my ($self, $lang) = @_;
  return exists($iso6393ToBCP{$lang}) ? $iso6393ToBCP{$lang} : $lang;
}

sub _get_dc_fields {
  my ($self, $rec, $dcfield, $targetfield) = @_;

  my @nodes;
  my %foundValues;
  for my $k (keys %{$rec}) {
    if ($k =~ m/^dc_$field_([a-z]+)$/) {
      my $lang = $1;
      for my $v (@{$rec->{$k}}) {
        $foundValues{$v} = 1;
        push @nodes, {
          name => $targetfield,
          value => $v,
          attributes => [
            {
              name => 'xml:lang',
              value => $self->_map_iso3_to_bcp($lang)
            }
          ]
        };
      }
    }
  }
  for my $k (keys %{$rec}) {
    if ($k =~ m/^dc_$field$/) {
      for my $v (@{$rec->{$k}}) {
        unless ($foundValues{$v}) {
          push @nodes, {
            name => $targetfield,
            value => $v
          };
        }
      }
    }
  }
  return \@nodes;
}

sub _bytes_string {
  my ($self, $bytes) = @_;
  return "" if(!defined($bytes));
  my @suffixes = ('B', 'kB', 'MB', 'GB', 'TB', 'EB');
  while($bytes > 1024)
  {
    shift @suffixes;
    $bytes /= 1024;
  }
  return sprintf("%.2f %s", $bytes,shift @suffixes);
}

sub _get_metadata_openaire {
  my ($self, $rec) = @_;

  my @metadata;

      #### MANDATORY ####

      # Resource Identifier (M)
      # datacite:identifier
      push @metadata, {
        name => 'datacite:identifier',
        value => 'https://'.$self->app->config->{phaidra}->{baseurl}.'/'.$rec->{pid},
        attributes => [
          {
            name => 'identifierType',
            value => 'URL'
          }
        ]
      };

      # Title (M)
      # datacite:title
      my $titles = $self->_get_dc_fields($rec, 'title', 'datacite:title');
      push @metadata, {
        name => 'datacite:titles',
        children => $titles
      };

      # Creator (M)
      # datacite:creator
      # creator = author
      # 
      # Contributor (MA)
      # datacite:contributor
      # contributor = not author, not publisher, not uploader
      # 
      # Publisher (MA)
      # dc:publisher
      # publisher = role publisher or bib_publisher
      my $roles;
      if (exists($rec->{roles_json})) {
        for my $roles_json_str (@{$rec->{roles_json}}) {
          $roles = $self->_get_roles($roles_json_str);
          last;
        }
      } else {
        if (exists($rec->{uwm_roles_json})) {
          for my $uwm_roles_json_str (@{$rec->{uwm_roles_json}}) {
            $roles = $self->_get_roles($uwm_roles_json_str);
            last;
          }
        }
      }
      my @creators = ();
      my @contributors = ();
      my @publishers = ();
      for my $role (@$roles) {
        switch ($role->{dcRole}) {
          case 'creator' {
            push @creators, $role;
          }
          case 'contributor' {
            push @contributors, $role;
          }
          case 'publisher' {
            push @publishers, $role;
          }
        }
      }

      push @metadata, {
        name => 'datacite:creators',
        children => $self->_rolesToNodes('creator', \@creators)
      };
      push @metadata, {
        name => 'datacite:contributors',
        children => $self->_rolesToNodes('contributor', \@creators)
      };

      if (scalar @publishers < 1) {
        # push bib_publisher
        if ($rec->{bib_publisher}) {
          for my $pub (@{$rec->{bib_publisher}}) {
            push @metadata, {
              name => 'dc:publisher',
              value => $pub
            };
          }
        }
      } else {
        for my $pub (@publishers) {
          push @metadata, {
            name => 'dc:publisher',
            value => $pub->{name}
          };
        }
      }

      # Publication Date (M)
      # datacite:date
      # Embargo Period Date (MA)
      # datacite:date
      my @dates;
      if (exists($rec->{bib_published})) {
        for my $pubDate (@{$rec->{bib_published}}) {
          push @dates, {
            name => 'datacite:date',
            value => $pubDate,
            attributes => [
              {
                name => 'dateType',
                value => 'Issued'
              }
            ]
          };
        }
      } else {
        if (exists($rec->{created})) {
          push @dates, {
            name => 'datacite:date',
            value => substr($rec->{created}, 0, 4),
            attributes => [
              {
                name => 'dateType',
                value => 'Issued'
              }
            ]
          };
        } else {
          $self->app->log->error("oai: could not find 'created' date in solr record pid[$rec->{pid}]");
        }
      }
      if (exists($rec->{dcterms_available})) {
        for my $embDate (@{$rec->{dcterms_available}}) {
          push @dates, {
            name => 'datacite:date',
            value => $embDate,
            attributes => [
              {
                name => 'dateType',
                value => 'Available'
              }
            ]
          };
        }
      }
      push @dates, {
        name => 'datacite:dates',
        children => \@dates
      };

      # Resource Type (M)
      # oaire:resourceType
      my $resourceTypeURI = '';
      my $resourceTypeGeneral = '';
      my $downloadObjectType = '';
      if ($rec->{resourcetype}) {
        my $resourcetype = '';
        switch ($rec->{resourcetype}) {
          case 'sound' {
            $resourceTypeGeneral = 'dataset';
            $downloadObjectType = 'dataset';
            $resourcetype = 'sound';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_18cc';
          }
          case 'book' {
            $resourceTypeGeneral = 'literature';
            $resourcetype = 'book';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_2f33';
          }
          case 'collection' { # this should likely not end up in oaiprovider at all
            $resourceTypeGeneral = 'dataset';
            $resourcetype = 'other';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_1843';
          }
          case 'dataset' {
            $resourceTypeGeneral = 'dataset';
            $resourcetype = 'dataset';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_ddb1';
          }
          case 'text' {
            $resourceTypeGeneral = 'literature';
            $downloadObjectType = 'fulltext';
            $resourcetype = 'text';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_18cf';
          }
          case 'journalarticle' {
            $resourceTypeGeneral = 'literature';
            $downloadObjectType = 'fulltext';
            $resourcetype = 'journal article';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_6501';
          }
          case 'image' {
            $resourceTypeGeneral = 'dataset';
            $resourcetype = 'image';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_c513';
          }
          case 'map' {
            $resourceTypeGeneral = 'dataset';
            $resourcetype = 'map';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_12cd';
          }
          case 'interactiveresource' {
            $resourceTypeGeneral = 'other research product';
            $resourcetype = 'interactive resource';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_e9a0';
          }
          case 'video' {
            $resourceTypeGeneral = 'dataset';
            $downloadObjectType = 'dataset';
            $resourcetype = 'video';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_12ce';
          }
          default {
            $resourceTypeGeneral = 'other research product';
            $resourcetype = 'other';
            $resourceTypeURI = 'http://purl.org/coar/resource_type/c_1843';
          }
        }
        if (exists($rec->{edm_hastype_id})) {
          for my $edmType (@{$rec->{edm_hastype_id}}) {
            if ($edmType eq 'https://pid.phaidra.org/vocabulary/VKA6-9XTY') {
              $resourceTypeGeneral = 'literature';
              $resourcetype = 'journal article';
              $resourceTypeURI = 'http://purl.org/coar/resource_type/c_6501';
            }
            last;
          }
        }
        push @metadata, {
          name => 'oaire:resourceType',
          value => $resourcetype,
          attributes => [
            {
              name => 'resourceTypeGeneral',
              value => $resourceTypeGeneral
            },
            {
              name => 'uri',
              value => $resourceTypeURI
            }
          ]
        };
      }

      # Access Rights (M)
      # datacite:rights
      my $rights = '';
      my $rightsURI = '';
      for my $dcRights (@{$rec->{dc_rights}}) {
        # legacy mapping
        switch ($dcRights) {
          case 'openAccess' {
            $rights = 'open access';
            $rightsURI = 'http://purl.org/coar/access_right/c_abf2';
          }
          case 'embargoedAccess' {
            $rights = 'embargoed access';
            $rightsURI = 'http://purl.org/coar/access_right/c_f1cf';
          }
          case 'restrictedAccess' {
            $rights = 'restricted access';
            $rightsURI = 'http://purl.org/coar/access_right/c_16ec';
          }
          case 'closedAccess' {
            $rights = 'metadata only accesss';
            $rightsURI = 'http://purl.org/coar/access_right/c_14cb';
          }
        }
      }
      for my $dcRightsId (@{$rec->{dcterms_accessrights_id}}) {
        switch ($dcRightsId) {
          case 'https://pid.phaidra.org/vocabulary/QW5R-NG4J' {
            $rights = 'open access';
            $rightsURI = 'http://purl.org/coar/access_right/c_abf2';
          }
          case 'https://pid.phaidra.org/vocabulary/AVFC-ZZSZ' {
            $rights = 'embargoed access';
            $rightsURI = 'http://purl.org/coar/access_right/c_f1cf';
          }
          case 'https://pid.phaidra.org/vocabulary/KC3K-CCGM' {
            $rights = 'restricted access';
            $rightsURI = 'http://purl.org/coar/access_right/c_16ec';
          }
          case 'https://pid.phaidra.org/vocabulary/QNGE-V02H' {
            $rights = 'metadata only accesss';
            $rightsURI = 'http://purl.org/coar/access_right/c_14cb';
          }
        }
      }
      push @metadata, {
        name => 'datacite:rights',
        value => $rights,
        attributes => [
          {
            name => 'rightsURI',
            value => $rightsURI
          }
        ]
      };

      #### MANDATORY IF AVAILABLE ####

      # Funding Reference (MA)
      # oaire:fundingReference
      my @refs;
      my @refNodes;
      my $fundRefsProj;
      if (exists($rec->{frapo_isoutputof_json})) {
        $fundRefsProj = $self->_get_funding_references($rec->{frapo_isoutputof_json});
      }
      for my $ref (@{$fundRefsProj}) {
        push @refs, $ref;
      }
      my $fundRefsFun;
      if (exists($rec->{frapo_hasfundingagency_json})) {
        $fundRefsFun = $self->_get_funding_references($rec->{frapo_hasfundingagency_json});
      }
      for my $ref (@{$fundRefsFun}) {
        push @refs, $ref;
      }
      for my $ref (@refs) {
        push @refNodes, {
          name => 'oaire:fundingReference',
          children => [
            {
              name => 'oaire:funderName',
              value => $ref->{funderName}
            },
            {
              name => 'oaire:awardNumber',
              value => $ref->{awardNumber}
            },
            {
              name => 'oaire:awardTitle',
              value => $ref->{awardTitle}
            }
          ]
        };
      }
      if (scalar @refNodes > 1) {
        push @metadata, {
          name => 'oaire:fundingReferences',
          children => \@refNodes
        };
      }

      # Language (MA)
      # dc:language
      for my $lang (@{$rec->{dc_language}}) {
        push @metadata, {
          name => 'dc:language',
          value => $lang
        };
      }

      # Description (MA)
      # dc:description
      my $descNodes = $self->_get_dc_fields($rec, 'description', 'dc:description');
      for my $descNode (@{$descNodes}) {
        push @metadata, $descNode;
      }

      # Subject (MA)
      # datacite:subject
      my $subjects = $self->_get_dc_fields($rec, 'subject', 'datacite:subject');
      push @metadata, {
        name => 'datacite:subjects',
        children => $subjects
      };

      # File Location (MA)
      # oaire:file
      my $mime;
      if ($rightsURI eq 'http://purl.org/coar/access_right/c_abf2') {
        my @attrs;
        push @attrs, {
          name => 'accessRightsURI',
          value => $rightsURI
        };
        my $mime;
        for my $format (@{$rec->{dc_format}}) {
          if ($format =~ m/*\/*/) {
            $mime = $format;
            push @attrs, {
              name => 'mimeType',
              value => $mime
            };
            last;
          }
        }
        if ($downloadObjectType) {
          push @attrs, {
            name => 'objectType',
            value => $downloadObjectType
          };
        }
        if ($resourceTypesToDownload{$resourceTypeURI}) {
          my $downloadUrl;
          if ($self->app->config->{feodra}->{version} eq '3.8') {
            $downloadUrl = 'https://'.$self->app->config->{phaidra}->{fedorabaseurl}.'/fedora/objects/'.$rec->{pid}.'/methods/bdef:Content/download'
          } else {
            $downloadUrl = 'https://'.$self->app->config->{phaidra}->{fedorabaseurl}.'/fedora/get/'.$rec->{pid}.'/bdef:Content/download'
          }
          push @metadata, {
            name => 'oaire:file',
            value => $downloadUrl,
            attributes => \@attrs
          };
        }
      }

      #### RECOMMENDED ####

      # Alternate Identifier (R)
      # datacite:alternateIdentifier
      my @ids;
      if (exists($rec->{dc_identifier})) {
        for my $id (@{$rec->{dc_identifier}}) {
          if (rindex($id, 'hdl:', 0) == 0) {
            push @ids, {
              name => 'datacite:alternateIdentifier',
              value => substr($id, 4),
              attributes => [
                {
                  name => 'alternateIdentifierType',
                  value => 'Handle'
                }
              ]
            };
          }
          if (rindex($id, 'doi:', 0) == 0) {
            push @ids, {
              name => 'datacite:alternateIdentifier',
              value => substr($id, 4),
              attributes => [
                {
                  name => 'alternateIdentifierType',
                  value => 'DOI'
                }
              ]
            };
          }
          if (rindex($id, 'urn:', 0) == 0) {
            push @ids, {
              name => 'datacite:alternateIdentifier',
              value => substr($id, 4),
              attributes => [
                {
                  name => 'alternateIdentifierType',
                  value => 'URN'
                }
              ]
            };
          }
        }
        if (scalar @ids > 0) {
          push @metadata, {
            name => 'datacite:alternateIdentifiers',
            children => \@ids
          };
        }
      }

      # Related Identifier (R)
      # datacite:relatedIdentifier
      my @relatedIdsNodes;
      for my $phaidraRel (keys %{$relations}) {
        if (exists($rec->{$phaidraRel})) {
          for my $pid (@{$rec->{$phaidraRel}}) {
            push @relatedIdsNodes, {
              name => 'datacite:relatedIdentifier',
              value => 'https://'.$self->app->config->{phaidra}->{baseurl}.'/'.$pid,
              attributes => [
                {
                  name => 'relatedIdentifierType',
                  value => 'URL'
                },
                {
                  name => 'relationType',
                  value => $relations{$phaidraRel}
                }
              ]
            };
          }
        }
      }
      if (scalar @relatedIdsNodes > 0) {
        push @metadata, {
          name => 'datacite:relatedIdentifiers',
          children => \@relatedIdsNodes
        };
      }
      
      # Format (R)
      # dc:format
      if ($mime) {
        push @metadata, {
          name => 'dc:format',
          value => $mime
        };
      }

      # Source (R)
      # dc:source
      my $sourceNodes = $self->_get_dc_fields($rec, 'source', 'dc:source');
      for my $sourceNode (@{$sourceNodes}) {
        push @metadata, $sourceNode;
      }

      # License Condition (R)
      # oaire:licenseCondition
      if (exists($rec->{dc_license})) {
        for my $lic (@{$rec->{dc_license}}) {
          if ($lic =~ m/^http(s)?:\/\//) {
            push @relatedIdsNodes, {
              name => 'oaire:licenseCondition',
              value => $lic,
              attributes => [
                {
                  name => 'uri',
                  value => $lic
                }
              ]
            };
          }
          if ($lic eq 'All rights reserved') {
            push @relatedIdsNodes, {
              name => 'oaire:licenseCondition',
              value => $lic,
              attributes => [
                {
                  name => 'uri',
                  value => 'http://rightsstatements.org/vocab/InC/1.0/'
                }
              ]
            };
          }
        }
      }

      # Coverage (R)
      # dc:coverage
      my $coverageNodes = $self->_get_dc_fields($rec, 'coverage', 'dc:coverage');
      for my $coverageNode (@{$coverageNodes}) {
        push @metadata, $coverageNode;
      }

      # Resource Version (R)
      # oaire:version
      my $oaireversion;
      my $oaireversionURI;
      for my $versionId (@{$rec->{dc_type}}) {
        # legacy mapping
        switch ($versionId) {
          case 'draft' {
            $oaireversion = 'AO';
            $oaireversionURI = 'http://purl.org/coar/version/c_b1a7d7d4d402bcce';
          }
          case 'acceptedVersion' {
            $oaireversion = 'AM';
            $oaireversionURI = 'http://purl.org/coar/version/c_ab4af688f83e57aa';
          }
          case 'updatedVersion' { # there was only one case of CVoR in our phaidra and no EVoR
            $oaireversion = 'CVoR';
            $oaireversionURI = 'http://purl.org/coar/version/c_e19f295774971610';
          }
          case 'submittedVersion' {
            $oaireversion = 'SMUR';
            $oaireversionURI = 'http://purl.org/coar/version/c_71e4c1898caa6e32';
          }
          case 'publishedVersion' {
            $oaireversion = 'VoR';
            $oaireversionURI = 'http://purl.org/coar/version/c_970fb48d4fbd8a85';
          }
        }
      }
      for my $versionId (@{$rec->{oaire_version_id}}) {
        switch ($versionId) {
          case 'https://pid.phaidra.org/vocabulary/TV31-080M' {
            $oaireversion = 'AO';
            $oaireversionURI = 'http://purl.org/coar/version/c_b1a7d7d4d402bcce';
          }
          case 'https://pid.phaidra.org/vocabulary/JTD4-R26P' {
            $oaireversion = 'SMUR';
            $oaireversionURI = 'http://purl.org/coar/version/c_71e4c1898caa6e32';
          }
          case 'https://pid.phaidra.org/vocabulary/PHXV-R6B3' {
            $oaireversion = 'AM';
            $oaireversionURI = 'http://purl.org/coar/version/c_ab4af688f83e57aa';
          }
          case 'https://pid.phaidra.org/vocabulary/83ZP-CPP2' {
            $oaireversion = 'P';
            $oaireversionURI = 'http://purl.org/coar/version/c_fa2ee174bc00049f';
          }
          case 'https://pid.phaidra.org/vocabulary/PMR8-3C8D' {
            $oaireversion = 'VoR';
            $oaireversionURI = 'http://purl.org/coar/version/c_970fb48d4fbd8a85';
          }
          case 'https://pid.phaidra.org/vocabulary/MT1G-APSB' {
            $oaireversion = 'CVoR';
            $oaireversionURI = 'http://purl.org/coar/version/c_e19f295774971610';
          }
          case 'https://pid.phaidra.org/vocabulary/SSQW-AP1S' {
            $oaireversion = 'EVoR';
            $oaireversionURI = 'http://purl.org/coar/version/c_dc82b40f9837b551';
          }
          case 'https://pid.phaidra.org/vocabulary/KZB5-0F5G' {
            $oaireversion = 'NA';
            $oaireversionURI = 'http://purl.org/coar/version/c_be7fb7dd8ff6fe43';
          }
        }
      }
      push @metadata, {
        name => 'oaire:version',
        value => $oaireversion,
        attributes => [
          {
            name => 'uri',
            value => $oaireversionURI
          }
        ]
      };

      # Citation Title (R)
      # oaire:citationTitle
      if (exists($rec->{bib_journal})) {
        for my $journal (@{$rec->{bib_journal}}) {
          push @metadata, {
            name => 'oaire:citationTitle',
            value => $journal;
          };
          last;
        }
      }

      # Citation Volume (R)
      # oaire:citationVolume
      if (exists($rec->{bib_volume})) {
        for my $vol (@{$rec->{bib_volume}}) {
          push @metadata, {
            name => 'oaire:citationVolume',
            value => $vol;
          };
          last;
        }
      }

      # Citation Issue (R)
      # oaire:citationIssue
      if (exists($rec->{bib_issue})) {
        for my $iss (@{$rec->{bib_issue}}) {
          push @metadata, {
            name => 'oaire:citationIssue',
            value => $iss;
          };
          last;
        }
      }

      # Citation Start Page (R)
      # oaire:citationStartPage

      # Citation End Page (R)
      # oaire:citationEndPage

      # Citation Edition (R)
      # oaire:citationEdition
      if (exists($rec->{bib_edition})) {
        for my $ed (@{$rec->{bib_edition}}) {
          push @metadata, {
            name => 'oaire:citationEdition',
            value => $ed;
          };
          last;
        }
      }

      # Citation Conference Place (R)
      # oaire:citationConferencePlace

      # Citation Conference Date (R)
      # oaire:citationConferenceDate

      #### OPTIONAL ####

      # Size (O)
      # datacite:size
      my @sizes;
      if (exists($rec->{size})) {
        for my $size (@{$rec->{size}}) {
          push @sizes, {
            name => 'datacite:size',
            value => $self->_bytes_string($size);
          };
          last;
        }
      }
      if (scalar @sizes > 0) {
        push @metadata, {
          name => 'datacite:sizes',
          children => \@sizes
        };
      }

      # Geo Location (O)
      # datacite:geoLocation

      # Audience (O)
      # dcterms:audience

      return \@metadata;
}

sub _get_metadata {
  my $self = shift;
  my $rec = shift;
  my $metadataPrefix = shift;

  switch ($metadataPrefix) {
    case 'oai_dc' {
      return $self->_get_metadata_dc($rec);
    }
    case 'oai_openaire' {
      return $self->_get_metadata_openaire($rec);
    }
  }
}

sub handler {
  my $self = shift;

  my $ns = "oai:".$self->config->{oai}->{oairepositoryidentifier}.":";
  my $uri_base = 'https://' . $self->config->{baseurl} . '/' . $self->config->{basepath} . '/oai';
  my $response_date = DateTime->now->iso8601 . 'Z';
  my $params = $self->req->params->to_hash;
  my $errors = [];
  my $set;
  my $sets;
  my $skip = 0;
  my $pagesize = $self->config->{oai}->{pagesize};
  my $verb = $params->{'verb'};
  $self->stash(
    uri_base              => $uri_base,
    request_uri           => $uri_base,
    response_date         => $response_date,
    errors                => $errors,
    params                => $params,
    repository_identitier => $self->config->{oai}->{oairepositoryidentifier},
    repository_name       => $self->config->{oai}->{repositoryname},
    ns                    => $ns,
    adminemail            => $self->config->{adminemail}
  );

  if ($verb and my $spec = $VERBS->{$verb}) {
    my $valid    = $spec->{valid};
    my $required = $spec->{required};

    if ($valid->{resumptionToken} and exists $params->{resumptionToken})
    {
      if (keys(%$params) > 2) {
        push @$errors, [badArgument => "resumptionToken cannot be combined with other parameters"];
      }
    } else {
      for my $key (keys %$params) {
        next if $key eq 'verb';
        unless ($valid->{$key}) {
          push @$errors, [badArgument => "parameter $key is illegal"];
        }
      }
      for my $key (@$required) {
        unless (exists $params->{$key}) {
          push @$errors, [badArgument => "parameter $key is missing"];
        }
      }
    }
  }
  else {
    push @$errors, [badVerb => "illegal OAI verb"];
  }

  if (@$errors) {
    $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
    return;
  }

  my $token;
  if (exists $params->{resumptionToken}) {
    if ($verb eq 'ListSets') {
      push @$errors, [badResumptionToken => "resumptionToken isn't necessary"];
    } else {
      eval {
        $token = $self->_deserialize($params->{resumptionToken});
        $params->{set}            = $token->{_s} if defined $token->{_s};
        $params->{from}           = $token->{_f} if defined $token->{_f};
        $params->{until}          = $token->{_u} if defined $token->{_u};
        $params->{metadataPrefix} = $token->{_m} if defined $token->{_m};
        $skip                     = $token->{_n} if defined $token->{_n};
        $self->stash(token => $token);
      };
      if($@){
        push @$errors, [badResumptionToken => "resumptionToken is not in the correct format"];
      };
    }
  }

  if (exists $params->{set} || ($verb eq 'ListSets')) {
    my $mongosets = $self->mongo->get_collection('oai_sets')->find();
    while (my $s = $mongosets->next) {
      $sets->{$s->{setSpec}} = $s;
    }
    unless ($sets) {
      push @$errors, [noSetHierarchy => "sets are not supported"];
    }
    if (exists $params->{set}) {
      unless ($set = $sets->{$params->{set}}) {
        push @$errors, [badArgument => "set does not exist"];
      }
    }
  }

  if (exists $params->{metadataPrefix}) {
    if ($params->{metadataPrefix} eq 'oai_dc' || ($params->{metadataPrefix} eq 'oai_openaire')) {
      $self->stash(metadataPrefix => $params->{metadataPrefix});
    } else {
      push @$errors, [cannotDisseminateFormat => "metadataPrefix $params->{metadataPrefix} is not supported" ];
    }
  }

  if (@$errors) {
    $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
    return;
  }

  if ($verb eq 'GetRecord') {
    my $id = $params->{identifier};
    $id =~ s/^$ns//;

    my $rec = $self->mongo->get_collection('oai_records')->find_one({"pid" => $id});
    if (defined $rec) {
      $self->stash(r => $rec, metadata => $self->_get_metadata($rec, $params->{metadataPrefix}));
      $self->render(template => 'oai/get_record', format => 'xml', handler => 'ep');
      return;
    }
    push @$errors, [idDoesNotExist => "identifier ".$params->{identifier}." is unknown or illegal"];
    $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
    return;

  } elsif ($verb eq 'Identify') {
    my $earliestDatestamp = '1970-01-01T00:00:01Z';
    my $rec = $self->mongo->get_collection('oai_records')->find()->sort({ "updated" => 1 })->next;
    if ($rec) {
      $earliestDatestamp = $rec->{created};
    }
    $self->stash(earliest_datestamp => $earliestDatestamp);
    $self->render(template => 'oai/identify', format => 'xml', handler => 'ep');
    return;

  } elsif ($verb eq 'ListIdentifiers' || $verb eq 'ListRecords') {
    my $from  = $params->{from};
    my $until = $params->{until};
    my $metadataPrefix = $params->{metadataPrefix};

    for my $datestamp (($from, $until)) {
      $datestamp || next;
      if ($datestamp !~ /^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}Z)?$/) {
        push @$errors, [badArgument => "datestamps must have the format YYYY-MM-DD or YYYY-MM-DDThh:mm:ssZ"];
        $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
        return;
      }
    }

    if ($from && $until && length($from) != length($until)) {
      push @$errors, [badArgument => "datestamps must have the same granularity"];
      $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
      return;
    }

    if ($from && $until && $from gt $until) {
      push @$errors, [badArgument => "from is more recent than until"];
      $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
      return;
    }

    if ($from && length($from) == 10) {
      $from = "${from}T00:00:00Z";
    }
    if ($until && length($until) == 10) {
      $until = "${until}T23:59:59Z";
    }

    my %filter;

    if ($from) {
      $filter{"updated"} = { '$gte' => DateTime::Format::ISO8601->parse_datetime($from) };
    }

    if ($until) {
      $filter{"updated"} = { '$lte' => DateTime::Format::ISO8601->parse_datetime($until) };
    }

    if ($params->{set}) {
      $filter{"setSpec"} = $params->{set};
    }

    my $total = $self->mongo->get_collection('oai_records')->count(\%filter);
    if ($total eq 0) {
      push @$errors, [noRecordsMatch => "no records found"];
      $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
      return;
    }
    $self->stash(total => $total);

    my $cursor = $self->mongo->get_collection('oai_records')->find(\%filter)->sort({ "updated" => 1 })->limit($pagesize)->skip($skip);
    my @records = ();
    while (my $rec = $cursor->next) {
      if ($verb eq 'ListIdentifiers') {
        push @records, {r => $rec};
      } else {
        push @records, {r => $rec, metadata => $self->_get_metadata($rec, $metadataPrefix)};
      }
    }
    $self->stash(records => \@records);

    if (($total > $pagesize) && (($skip + $pagesize) < $total)) {
      my $t;
      $t->{_n} = $skip + $pagesize;
      $t->{_s} = $set->{setSpec} if defined $set;
      $t->{_f} = $from if defined $from;
      $t->{_u} = $until if defined $until;
      $t->{_m} = $metadataPrefix if defined $metadataPrefix;
      $self->stash(resumption_token => $self->_serialize($t));
    } else {
      $self->stash(resumption_token => undef);
    }

    $self->app->log->debug("oai list response: verb[$verb] skip[$skip] pagesize[$pagesize] total[$total] from[$from] until[$until] set[".$set->{setSpec}."] restoken[".$self->stash('resumption_token')."]");

    if ($verb eq 'ListIdentifiers') {
      $self->render(template => 'oai/list_identifiers', format => 'xml', handler => 'ep');
    } else {
      $self->render(template => 'oai/list_records', format => 'xml', handler => 'ep');
    }

  } elsif ($verb eq 'ListMetadataFormats') {

    if (my $id = $params->{identifier}) {
      $id =~ s/^$ns//;
      my $rec = $self->mongo->get_collection('oai_records')->find_one({"pid" => $id});
      unless (defined $rec) {
        push @$errors, [idDoesNotExist => "identifier ".$params->{identifier}." is unknown or illegal"];
        $self->render(template => 'oai/error', format => 'xml', handler => 'ep');
        return;
      }
    }
    $self->render(template => 'oai/list_metadata_formats', format => 'xml', handler => 'ep');
    return;

  } elsif ($verb eq 'ListSets') {
    for my $setSpec (keys %{$sets}) {
      $sets->{$setSpec}->{metadata} = $self->_get_metadata($sets->{$setSpec}->{setDescription}, 'oai_dc')
    }
    $self->stash(sets => $sets);
    $self->render(template => 'oai/list_sets', format => 'xml', handler => 'ep');
    return;
  }
}

1;
