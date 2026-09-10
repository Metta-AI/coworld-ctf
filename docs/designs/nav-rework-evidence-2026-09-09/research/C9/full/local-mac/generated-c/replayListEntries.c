N_LIB_PRIVATE N_NIMCALL(void, replayListEntries__OOZsrcZshellZbody95nav_u2390)(tyObject_BodyNavSeatcolonObjectType___0c87LTWzqtz7zmat1zT0Kw* seat_p0, NI slot_p1) {
	NI base_1;
	NI TM__fw0EGWK0CbR9aJ84zaF6cBg_273;
	nimfr_("replayListEntries", "body_nav.nim");
{	if (nimMulInt(slot_p1, (*(*seat_p0).dangerSourceCache).capacity, &TM__fw0EGWK0CbR9aJ84zaF6cBg_273)) { raiseOverflow(); goto BeforeRet_;
	};
	base_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_273);
	{
		NI offset_1;
		NI colontmp_;
		NI TM__fw0EGWK0CbR9aJ84zaF6cBg_274;
		NI i_1;
		offset_1 = (NI)0;
		colontmp_ = (NI)0;
		if ((NU)(slot_p1) > (NU)(63)){ raiseIndexError2(slot_p1, 63); goto BeforeRet_;
		}
		if (nimAddInt(base_1, ((NI) ((*(*seat_p0).dangerSourceCache).slots[(slot_p1)- 0].listLength)), &TM__fw0EGWK0CbR9aJ84zaF6cBg_274)) { raiseOverflow(); goto BeforeRet_;
		};
		colontmp_ = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_274);
		i_1 = base_1;
		{
			while (1) {
				tyObject_DangerSourceEntry__Q9arhEVQ9bgP16CdlIu9b9a9bDQ entry_1;
				NI TM__fw0EGWK0CbR9aJ84zaF6cBg_275;
				if (!(i_1 < colontmp_)) goto LA3;
				offset_1 = i_1;
				if (offset_1 < 0 || offset_1 >= (*(*seat_p0).dangerSourceCache).entries.len){ raiseIndexError2(offset_1,(*(*seat_p0).dangerSourceCache).entries.len-1); goto BeforeRet_;
				}
				entry_1 = (*(*seat_p0).dangerSourceCache).entries.p->data[offset_1];
				if (entry_1.gridIndex < 0 || entry_1.gridIndex >= (*seat_p0).danger.values.len){ raiseIndexError2(entry_1.gridIndex,(*seat_p0).danger.values.len-1); goto BeforeRet_;
				}
				pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[entry_1.gridIndex]), entry_1.weight);
				if (nimAddInt(i_1, ((NI)1), &TM__fw0EGWK0CbR9aJ84zaF6cBg_275)) { raiseOverflow(); goto BeforeRet_;
				};
				i_1 = (NI)(TM__fw0EGWK0CbR9aJ84zaF6cBg_275);
			} LA3: ;
		}
	}
	}BeforeRet_: ;
	popFrame();
}