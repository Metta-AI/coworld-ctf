N_LIB_PRIVATE N_NIMCALL(void, replayList__bench95danger95lazy95list_u4732)(tyObject_BodyNavSeatcolonObjectType___Uc8v9aEG9ag64r1QaUbvXJng* seat_p0, tyObject_ListStore__CLbBNJfvhiylv1GHDNX5Gw* store_p1, NI listIndex_p2) {
	NI base_1;
	NI TM__W7aMY615OVJySGXx9cwCHLQ_240;
	nimfr_("replayList", "bench_danger_lazy_list.nim");
{	if (nimMulInt(listIndex_p2, (*store_p1).capacity, &TM__W7aMY615OVJySGXx9cwCHLQ_240)) { raiseOverflow(); goto BeforeRet_;
	};
	base_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_240);
	{
		NI offset_1;
		NI colontmp_;
		NI TM__W7aMY615OVJySGXx9cwCHLQ_241;
		NI i_1;
		offset_1 = (NI)0;
		colontmp_ = (NI)0;
		if (listIndex_p2 < 0 || listIndex_p2 >= (*store_p1).lengths.len){ raiseIndexError2(listIndex_p2,(*store_p1).lengths.len-1); goto BeforeRet_;
		}
		if (nimAddInt(base_1, ((NI) ((*store_p1).lengths.p->data[listIndex_p2])), &TM__W7aMY615OVJySGXx9cwCHLQ_241)) { raiseOverflow(); goto BeforeRet_;
		};
		colontmp_ = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_241);
		i_1 = base_1;
		{
			while (1) {
				tyObject_ListEntry__J0WS86jeI1rcPVztV7pfag entry_1;
				NI TM__W7aMY615OVJySGXx9cwCHLQ_242;
				if (!(i_1 < colontmp_)) goto LA3;
				offset_1 = i_1;
				if (offset_1 < 0 || offset_1 >= (*store_p1).entries.len){ raiseIndexError2(offset_1,(*store_p1).entries.len-1); goto BeforeRet_;
				}
				entry_1 = (*store_p1).entries.p->data[offset_1];
				if (entry_1.gridIndex < 0 || entry_1.gridIndex >= (*seat_p0).danger.values.len){ raiseIndexError2(entry_1.gridIndex,(*seat_p0).danger.values.len-1); goto BeforeRet_;
				}
				pluseq___OOZOOZOOZOOZOOZOnimbyZpkgsZbumpyZsrcZbumpy_u130((&(*seat_p0).danger.values.p->data[entry_1.gridIndex]), entry_1.weight);
				if (nimAddInt(i_1, ((NI)1), &TM__W7aMY615OVJySGXx9cwCHLQ_242)) { raiseOverflow(); goto BeforeRet_;
				};
				i_1 = (NI)(TM__W7aMY615OVJySGXx9cwCHLQ_242);
			} LA3: ;
		}
	}
	}BeforeRet_: ;
	popFrame();
}